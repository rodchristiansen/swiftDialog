//
//  ConsoleView.swift
//  Managed Notifications Dialog
//
//  Real-time output display. Colour-coded by level, monospaced,
//  auto-scrolls to the bottom.
//

import SwiftUI

struct ConsoleView: View {
    let outputLines: [DialogRunner.OutputLine]

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(outputLines) { line in
                        Text(line.text)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(line.level.color)
                            .textSelection(.enabled)
                            .id(line.id)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.black.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .onChange(of: outputLines.count) {
                if let last = outputLines.last {
                    withAnimation(.easeOut(duration: 0.1)) {
                        scrollProxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}
