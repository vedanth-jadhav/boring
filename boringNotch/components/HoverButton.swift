//
//  HoverButton.swift
//  boringNotch
//
//  Created by Kraigo on 04.09.2024.
//

import SwiftUI

struct HoverButton: View {
    var icon: String
    var iconColor: Color = .primary
    var scale: Image.Scale = .medium
    var badgeIcon: String? = nil
    var action: () -> Void
    var contentTransition: ContentTransition = .symbolEffect

    @State private var isHovering = false

    var body: some View {
        let size = CGFloat(scale == .large ? 40 : 30)

        Button(action: action) {
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .frame(width: size, height: size)
                .overlay {
                    Capsule()
                        .fill(isHovering ? Color.gray.opacity(0.2) : .clear)
                        .frame(width: size, height: size)
                        .overlay {
                            Image(systemName: icon)
                                .foregroundColor(iconColor)
                                .contentTransition(contentTransition)
                                .font(scale == .large ? .largeTitle : .body)
                                .overlay(alignment: .topTrailing) {
                                    if let badgeIcon {
                                        Image(systemName: badgeIcon)
                                            .font(.system(size: 8, weight: .bold))
                                            .foregroundStyle(iconColor)
                                            .offset(x: 7, y: -5)
                                    }
                                }
                        }
                }
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.smooth(duration: 0.3)) {
                isHovering = hovering
            }
        }
    }
}
