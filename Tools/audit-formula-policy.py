#!/usr/bin/env python3
"""Compare saved five-page policy experiments; never run an inference model."""
import collections
import json
import pathlib
import sys
import unicodedata
import xml.etree.ElementTree as ET

root = pathlib.Path(sys.argv[1])


def read(name):
    return json.loads((root / name).read_text())


def iou(a, b):
    overlap = max(0, min(a['xmax'], b['xmax']) - max(a['xmin'], b['xmin'])) * max(
        0, min(a['ymax'], b['ymax']) - max(a['ymin'], b['ymin']))
    area = lambda v: max(0, v['xmax'] - v['xmin']) * max(0, v['ymax'] - v['ymin'])
    return overlap / max(1, area(a) + area(b) - overlap)


def text(observation):
    return observation.get('selectedTextOverride') or observation['candidates'][0]['text']


def clean(value):
    return ' '.join((value or '').split())


def tokens(mathml):
    tree = ET.fromstring(mathml)
    result = ''.join(n.text or '' for n in tree.iter() if n.tag.rsplit('}', 1)[-1] in ['mi', 'mn', 'mo', 'mtext'])
    return ''.join(c for c in unicodedata.normalize('NFKC', result) if not c.isspace() and c not in '\u2061\u2062\u2063\u2064')


before = read('baseline-final-extraction.json')
after = read('after-final-extraction.json')
before_raw = read('baseline-source-extraction.json')
after_raw = read('after-source-extraction.json')
after_ready = read('after-final_ready.json')
reader_rows = read('after-device/persisted-reader-rows.json')['rows']


def persisted_reader_contains(page, formula):
    block = next((b for b in page['blocks'] if any(s.get('formulaID') == formula['id'] for s in b['segments'])), None)
    if not block or not formula.get('spokenText'):
        return False
    chunks = {c['id'] for c in after_ready['chunks'] if block['id'] in (c.get('sourceBlockIDs') or []) and
              clean(formula['spokenText']) in clean(c.get('spokenText'))}
    return any(chunks.intersection(row['chunk_ids']) and clean(formula['spokenText']) in clean(row['accessibility_label']) for row in reader_rows)

report = {'scope': 'Same five original pages on iPhone. Candidate acceptance is not semantic accuracy.',
          'baseline_run': before['id'], 'after_run': after['id'], 'pages': [],
          'preservation': [], 'retired_letters': [], 'recoveries': [], 'reviewed_cases': []}
# These two old accepted crops were visually reviewed against page_0116:
# the source x² had an invented i, and source 3x² had an invented leading 1.
known_old_errors = {'p0002.formula.0008', 'p0002.formula.0011'}

for bp, ap, br, ar in zip(before['pages'], after['pages'], before_raw['pages'], after_raw['pages']):
    assert bp['sourceSHA256'] == ap['sourceSHA256']
    bregs = {r['id']: r for r in br['layoutRegions']}
    bforms = {f['id']: f for f in br['formulaRegions']}
    aforms = {f['id']: f for f in ar['formulaRegions']}
    afinal = {f['id']: f for f in ap['formulas']}
    bobs = {o['id']: o for o in br['rawOCR']}
    report['pages'].append({'page': bp['id'], 'before_candidates': len(bp['formulas']),
        'after_candidates': len(ap['formulas']), 'before_spoken': sum(bool(f.get('spokenText')) for f in bp['formulas']),
        'after_spoken': sum(bool(f.get('spokenText')) for f in ap['formulas'])})
    for f in bp['formulas']:
        raw = bforms[f['id']]
        region = bregs[raw['layoutRegionID']]
        letter = region.get('detectionSource') == 'vision_range_math_proposal_v1' and len(region.get('proposalText', '')) == 1
        if letter:
            obs = bobs[region['sourceObservationID']]
            current_obs = next((o for o in ar['rawOCR'] if text(o) == text(obs) and iou(o['bboxPageXYXY'], obs['bboxPageXYXY']) > .85), None)
            state = 'missing_source_line'
            if current_obs:
                lo, hi = region['sourceRangeUTF16']
                segments = [s for b in ap['blocks'] for s in b['segments'] if any(
                    r['observationID'] == current_obs['id'] and r['rangeUTF16'][0] <= lo and r['rangeUTF16'][1] >= hi for r in s['sourceRefs'])]
                state = 'missing_source_span'
                if segments:
                    state = 'plain_text' if all(s['kind'] == 'text' for s in segments) else (
                        'complete_formula' if all(afinal.get(s.get('formulaID'), {}).get('spokenText') for s in segments if s['kind'] == 'math') else 'held_by_formula')
            report['retired_letters'].append({'before_id': f['id'], 'letter': region['proposalText'], 'state': state})
            continue
        if not f.get('spokenText'):
            continue
        match = max(ap['formulas'], key=lambda g: iou(f['bboxPageXYXY'], g['bboxPageXYXY']), default=None)
        score = iou(f['bboxPageXYXY'], match['bboxPageXYXY']) if match else 0
        report['preservation'].append({'before_id': f['id'], 'after_id': match['id'] if match else None,
            'iou': score, 'known_old_recognition_error': f['id'] in known_old_errors,
            'before_speech': f['spokenText'], 'after_speech': match.get('spokenText') if match else None,
            'persisted_reader_contains_speech': bool(match and persisted_reader_contains(ap, match)),
            'exact_speech_preserved': score >= .5 and clean(f['spokenText']) == clean(match.get('spokenText'))})
    for f in ap['formulas']:
        if not f.get('spokenText'):
            continue
        previous = max(bp['formulas'], key=lambda g: iou(f['bboxPageXYXY'], g['bboxPageXYXY']), default=None)
        if previous and iou(f['bboxPageXYXY'], previous['bboxPageXYXY']) >= .5 and not previous.get('spokenText'):
            report['recoveries'].append({'before_id': previous['id'], 'after_id': f['id'], 'latex': f.get('latex'),
                'speech': f['spokenText'], 'merge_methods': f['mergeMethods']})

# Independent visual annotations for specific expressions, never provided to models.
expected = {'p0001.formula.0002': 'a×1=a', 'p0001.formula.0011': '(abc)',
            'p0002.formula.0007': '5x2+2x', 'p0002.formula.0010': '4x3+2x2+3x+3x2+8',
            'p0002.formula.0012': '2x2'}
expected_powers = {'p0002.formula.0007': [('x', '2')],
                   'p0002.formula.0010': [('x', '3'), ('x', '2'), ('x', '2')],
                   'p0002.formula.0012': [('x', '2')]}
for page, raw_page, new_page, new_raw in zip(before['pages'], before_raw['pages'], after['pages'], after_raw['pages']):
    new_raw_by_id = {f['id']: f for f in new_raw['formulaRegions']}
    for f in page['formulas']:
        if f['id'] not in expected:
            continue
        g = max(new_page['formulas'], key=lambda x: iou(f['bboxPageXYXY'], x['bboxPageXYXY']))
        raw = new_raw_by_id[g['id']]
        tree = ET.fromstring(raw['mathML'])
        powers = [(tokens(ET.tostring(list(n)[0], encoding='unicode')), tokens(ET.tostring(list(n)[1], encoding='unicode')))
                  for n in tree.iter() if n.tag.rsplit('}', 1)[-1] == 'msup' and len(n) == 2]
        fractions = [(tokens(ET.tostring(list(n)[0], encoding='unicode')), tokens(ET.tostring(list(n)[1], encoding='unicode')))
                     for n in tree.iter() if n.tag.rsplit('}', 1)[-1] == 'mfrac' and len(n) == 2]
        report['reviewed_cases'].append({'before_id': f['id'], 'after_id': g['id'], 'speech_available': bool(g.get('spokenText')),
            'token_sequence_matches_visual_annotation': tokens(raw['mathML']) == expected[f['id']],
            'power_structure_matches_visual_annotation': powers == expected_powers.get(f['id'], []),
            'fraction_structure_matches_visual_annotation': fractions == ([('b', 'c')] if f['id'] == 'p0001.formula.0011' else []),
            'persisted_reader_contains_speech': persisted_reader_contains(new_page, g),
            'recognition_latex': g.get('latex'), 'speech': g.get('spokenText')})

report['retired_letter_states'] = dict(collections.Counter(v['state'] for v in report['retired_letters']))
report['eligible_baseline_speech_preserved'] = sum(v['exact_speech_preserved'] and v['persisted_reader_contains_speech'] for v in report['preservation'] if not v['known_old_recognition_error'])
report['eligible_baseline_speech_total'] = sum(not v['known_old_recognition_error'] for v in report['preservation'])
report['remaining_held'] = [{'id': f['id'], 'latex': f.get('latex'), 'source': f['sourceText'], 'reasons': f['reviewReasons']}
    for p in after['pages'] for f in p['formulas'] if not f.get('spokenText')]
report['baseline_wall_ms'] = read('baseline-device/completed.json')['wall_ms']
report['after_wall_ms'] = read('after-device/completed.json')['wall_ms']
for label, document in [('baseline', before_raw), ('after', after_raw)]:
    components = [c for p in document['pages'] for c in p['components'] if c['component'] == 'unimernet']
    report[label + '_unimernet_requests'] = sum(c['metrics'].get('attempted') or 0 for c in components)
    report[label + '_unimernet_inference_ms'] = sum(c['metrics'].get('inference_ms') or 0 for c in components)
report['limitations'] = ['Five pages and one timing sample per version; not a general accuracy or speed benchmark',
    'Only the listed recovered expressions have independent token annotations; candidate acceptance is not proof of source fidelity',
    'Typography words can remain in MathCAT output for actual formula crops; no global font stripping',
    'No human VoiceOver listening study performed']
(root / 'audit.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
print(json.dumps({k: v for k, v in report.items() if k not in ['preservation', 'retired_letters', 'remaining_held']}, ensure_ascii=False, indent=2))
