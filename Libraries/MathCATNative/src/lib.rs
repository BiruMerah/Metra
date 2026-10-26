use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};
use libmathcat::interface::{get_preference, get_spoken_text, get_version, set_mathml, set_preference, set_rules_dir};
use serde_json::{json, Map, Value};

// Caller executes this entire transaction on its one fixed OS thread.
// MathCAT owns thread-local state; no async or cross-thread call occurs here.
#[no_mangle]
pub unsafe extern "C" fn metra_mathcat_convert(rules: *const c_char, mathml: *const c_char) -> *mut c_char {
    let result = catch_unwind(AssertUnwindSafe(|| -> Result<Value, String> {
        if rules.is_null() || mathml.is_null() { return Err("Null MathCAT input".into()); }
        let rules = CStr::from_ptr(rules).to_str().map_err(|e| e.to_string())?.to_string();
        let mathml = CStr::from_ptr(mathml).to_str().map_err(|e| e.to_string())?.to_string();
        if !std::path::Path::new(&rules).join("Languages/id/SimpleSpeak_Rules.yaml").is_file() {
            return Err("Bundled Indonesian SimpleSpeak rules missing; no language fallback allowed".into());
        }
        set_rules_dir(rules).map_err(|e| format!("{:#}", e))?;
        let preferences = [("Language", "id"), ("SpeechStyle", "SimpleSpeak"), ("Verbosity", "Medium"),
            ("TTS", "None"), ("DecimalSeparator", ","), ("DecimalSeparators", ","), ("BlockSeparators", ".\u{00a0}\u{202f}")];
        for (name, value) in preferences { set_preference(name.into(), value.into()).map_err(|e| format!("{name}: {e:#}"))?; }
        let canonical = set_mathml(mathml).map_err(|e| format!("{:#}", e))?;
        let spoken = get_spoken_text().map_err(|e| format!("{:#}", e))?;
        let mut effective = Map::new();
        for (name, _) in preferences { effective.insert(name.into(), json!(get_preference(name.into()).map_err(|e| format!("{:#}",e))?)); }
        if effective.get("Language") != Some(&json!("id")) || effective.get("SpeechStyle") != Some(&json!("SimpleSpeak")) {
            return Err(format!("Unexpected MathCAT profile: {effective:?}"));
        }
        Ok(json!({"ok":true, "spokenText":spoken, "canonicalMathML":canonical, "profile":effective, "version":get_version()}))
    }));
    let payload = match result { Ok(Ok(v)) => v, Ok(Err(e)) => json!({"ok":false,"error":e}), Err(_) => json!({"ok":false,"error":"MathCAT panic caught at C ABI boundary"}) };
    CString::new(payload.to_string()).unwrap().into_raw()
}

#[no_mangle]
pub unsafe extern "C" fn metra_mathcat_free(result: *mut c_char) {
    if !result.is_null() { drop(CString::from_raw(result)); }
}
