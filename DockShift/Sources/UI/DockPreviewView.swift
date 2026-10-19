// DockPreviewView.swift — DockShift
// A read-only miniature of a saved Dock: apps, a separator, then folders/files, in Dock order.
// Takes precomputed tiles (DockService.tiles checks the disk for every tile, so the caller
// computes them once per Dock revision instead of on every render).
import SwiftUI
import AppKit

struct DockPreviewView: View {
    let tiles: [DockTileInfo]
    var iconSize: CGFloat = 40

    var body: some View {
        let apps = tiles.filter { $0.section == .apps }
        let others = tiles.filter { $0.section == .others }
        if tiles.isEmpty {
            Text("This Dock has no items.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: iconSize + 16)
        } else {
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(apps) { DockTileView(tile: $0, size: iconSize) }
                    if !apps.isEmpty && !others.isEmpty {
                        Divider()
                            .frame(height: iconSize * 0.8)
                            .padding(.horizontal, 6)
                    }
                    ForEach(others) { DockTileView(tile: $0, size: iconSize) }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.automatic)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Dock preview, \(tiles.count) items")
        }
    }
}

private struct DockTileView: View {
    let tile: DockTileInfo
    let size: CGFloat

    var body: some View {
        switch tile.kind {
        case .spacer, .flexSpacer:
            gap(width: size)
        case .smallSpacer:
            gap(width: size / 2)
        default:
            Image(nsImage: DockService.shared.icon(for: tile))
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .opacity(tile.isMissing ? 0.35 : 1)
                .overlay(alignment: .bottomTrailing) {
                    if tile.isMissing {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                            .font(.system(size: 13))
                            .offset(x: 2, y: 2)
                    }
                }
                .help(tooltip)
                .accessibilityLabel(tooltip)
        }
    }

    private var tooltip: String {
        tile.isMissing ? "\(tile.label) — not found on this Mac, skipped when applied" : tile.label
    }

    private func gap(width: CGFloat) -> some View {
        Color.clear
            .frame(width: width, height: size)
            .contentShape(Rectangle())   // give the empty gap a hover area for the tooltip
            .help("Spacer")
            .accessibilityLabel("Spacer")
    }
}
