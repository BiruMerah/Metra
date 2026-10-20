//
//  ActionButton.swift
//  Metra
//
//  Created by Fidel Fausta Cavell on 20/10/26.
//

import SwiftUI

struct ActionButton: View {
    let title: String
    var accessibilityLabel: String? = nil
    var size: CGSize? = nil
    var width: CGFloat? = nil
    var height: CGFloat? = nil
    let action: () -> Void
    
    init(
        title: String,
        accessibilityLabel: String? = nil,
        width: CGFloat? = nil,
        height: CGFloat? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.accessibilityLabel = accessibilityLabel
        self.width = size?.width ?? width
        self.height = size?.height ?? height
        self.action = action
    }
    
    var body: some View {
        Button(action: action) {
            if let width {
                Text(title)
                    .frame(width: width, height: height)
            } else {
                Text(title)
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
            }
        }
        .buttonStyle(.glassProminent)
        .accessibilityLabel(accessibilityLabel ?? title)
    }
}

#Preview {
    VStack(spacing: 16) {
        ActionButton(
            title: "Default Size (Full Width)",
            action: {}
        )
        
        ActionButton(
            title: "Explicit Width & Height",
            width: 200,
            height: 44,
            action: {}
        )
    }
    .padding()
}
