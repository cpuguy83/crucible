import SwiftUI
import BuildKitCore
import BuildKitContainerization
import BuildKitContainerCLI
import AppKit
import Darwin

@main
struct CrucibleApp: App {
    @StateObject private var viewModel: TrayViewModel
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)

        let vm = TrayViewModel()
        _viewModel = StateObject(wrappedValue: vm)
        AppDelegate.viewModel = vm

        // The framework's host-side unix/vsock relay can write to a socket
        // after a build client closes its end. Darwin's default behavior for
        // that is process termination via SIGPIPE, which makes the app/VM
        // disappear immediately after a build completes. Ignore it globally;
        // write calls still fail with EPIPE and relay code can clean up.
        signal(SIGPIPE, SIG_IGN)
    }

    var body: some Scene {
        MenuBarExtra {
            TrayMenu(viewModel: viewModel)
        } label: {
            DalekMenuBarIcon(state: viewModel.state)
        }
        .menuBarExtraStyle(.menu)
    }
}

struct DalekMenuBarIcon: View {
    let state: BuildKitState

    private enum IconState {
        case stopped
        case busy
        case running
        case degraded
        case error
    }

    private var iconState: IconState {
        switch state {
        case .stopped:
            return .stopped
        case .starting, .stopping:
            return .busy
        case .running:
            return .running
        case .degraded:
            return .degraded
        case .error:
            return .error
        }
    }

    private var accessibilityState: String {
        switch iconState {
        case .stopped: return "stopped"
        case .busy: return "busy"
        case .running: return "running"
        case .degraded: return "degraded"
        case .error: return "error"
        }
    }

    var body: some View {
        Image(nsImage: Self.image(for: iconState))
            .resizable()
            .aspectRatio(contentMode: .fit)
        .frame(width: 22, height: 18)
        .accessibilityLabel("Crucible \(accessibilityState)")
    }

    private static func image(for state: IconState) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 18), flipped: true) { rect in
            drawIcon(in: rect, state: state)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func drawIcon(in bounds: CGRect, state: IconState) {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: bounds.minX + x * bounds.width / 22, y: bounds.minY + y * bounds.height / 18)
        }
        func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
            CGRect(
                x: bounds.minX + x * bounds.width / 22,
                y: bounds.minY + y * bounds.height / 18,
                width: width * bounds.width / 22,
                height: height * bounds.height / 18
            )
        }

        let scale = min(bounds.width / 22, bounds.height / 18)
        let fillOpacity: CGFloat = switch state {
        case .running: 0.28
        case .busy, .degraded, .error: 0.18
        case .stopped: 0.06
        }

        func stroke(_ path: NSBezierPath, opacity: CGFloat = 1, width: CGFloat = 1.05) {
            NSColor.black.withAlphaComponent(opacity).setStroke()
            path.lineWidth = width * scale
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
        }

        func fill(_ path: NSBezierPath, opacity: CGFloat = 1) {
            NSColor.black.withAlphaComponent(opacity).setFill()
            path.fill()
        }

        for nubX in [7.4, 13.0] {
            let nub = NSBezierPath()
            nub.move(to: point(nubX, 2.25))
            nub.line(to: point(nubX, 1.2))
            stroke(nub, opacity: 0.9, width: 0.9)
            fill(NSBezierPath(ovalIn: rect(nubX - 0.45, 0.85, 0.9, 0.9)), opacity: 0.9)
        }

        let dome = NSBezierPath()
        dome.move(to: point(5.7, 5.55))
        dome.curve(to: point(10.2, 2.1), controlPoint1: point(6.2, 3.6), controlPoint2: point(7.9, 2.1))
        dome.curve(to: point(14.8, 5.55), controlPoint1: point(12.6, 2.1), controlPoint2: point(14.3, 3.6))
        dome.close()
        fill(dome, opacity: fillOpacity + 0.08)
        stroke(dome, width: 1.15)

        let eyeEnd: CGPoint
        let eyeLens: CGRect
        if state == .stopped || state == .error {
            eyeEnd = point(19.0, 5.45)
            eyeLens = rect(18.65, 4.95, 2.35, 1.15)
        } else {
            eyeEnd = point(19.0, 2.05)
            eyeLens = rect(18.65, 1.48, 2.35, 1.15)
        }

        let eye = NSBezierPath()
        eye.move(to: point(11.8, 3.75))
        eye.line(to: eyeEnd)
        stroke(eye, width: 0.95)
        fill(NSBezierPath(ovalIn: eyeLens))

        for y in [5.9, 6.75, 7.6] {
            let neck = NSBezierPath()
            neck.move(to: point(5.9, y))
            neck.line(to: point(14.6, y))
            stroke(neck, opacity: 0.9, width: 0.8)
        }

        let shoulders = NSBezierPath()
        shoulders.move(to: point(5.2, 8.05))
        shoulders.line(to: point(15.2, 8.05))
        shoulders.line(to: point(15.9, 9.05))
        shoulders.line(to: point(4.5, 9.05))
        shoulders.close()
        fill(shoulders, opacity: fillOpacity + 0.05)
        stroke(shoulders, opacity: 0.95, width: 0.9)

        let midBand = NSBezierPath()
        midBand.move(to: point(4.4, 9.55))
        midBand.line(to: point(15.9, 9.55))
        midBand.line(to: point(17.0, 10.6))
        midBand.line(to: point(3.7, 10.6))
        midBand.close()
        fill(midBand, opacity: fillOpacity + 0.02)
        stroke(midBand, opacity: 0.95, width: 0.9)

        let arm = NSBezierPath()
        arm.move(to: point(15.8, 9.8))
        arm.line(to: point(20.0, 9.8))
        arm.line(to: point(21.1, 10.25))
        stroke(arm, opacity: 0.85, width: 0.85)

        let skirt = NSBezierPath()
        skirt.move(to: point(4.5, 10.65))
        skirt.line(to: point(16.2, 10.65))
        skirt.line(to: point(18.0, 16.7))
        skirt.line(to: point(2.8, 16.7))
        skirt.close()
        fill(skirt, opacity: fillOpacity)
        stroke(skirt, width: 1.15)

        for x in [6.3, 9.0, 11.8, 14.6] {
            let panel = NSBezierPath()
            panel.move(to: point(x, 10.85))
            let baseX = 10.4 + (x - 10.4) * 1.35
            panel.line(to: point(baseX, 16.45))
            stroke(panel, opacity: 0.65, width: 0.65)
        }

        let pips: [(CGFloat, CGFloat)] = [
            (6.2, 11.6), (10.2, 11.7), (14.2, 11.6),
            (5.4, 13.25), (9.5, 13.35), (13.7, 13.25),
            (4.8, 14.95), (8.8, 15.05), (13.0, 15.05), (16.4, 14.95)
        ]
        for (index, pipPoint) in pips.enumerated() {
            let opacity = pipOpacity(index: index, state: state)
            let pip = NSBezierPath(ovalIn: rect(pipPoint.0 - 0.58, pipPoint.1 - 0.58, 1.16, 1.16))
            if state == .stopped {
                stroke(pip, opacity: opacity, width: 0.8)
            } else {
                fill(pip, opacity: opacity)
            }
        }

        let base = NSBezierPath()
        base.move(to: point(2.4, 17.2))
        base.line(to: point(18.4, 17.2))
        stroke(base, opacity: 0.95, width: 1.25)

        drawStatusBadge(in: bounds, state: state, scale: scale)
    }

    private static func pipOpacity(index: Int, state: IconState) -> CGFloat {
        switch state {
        case .running:
            return 0.95
        case .busy:
            return index.isMultiple(of: 2) ? 0.5 : 0.9
        case .degraded:
            return index.isMultiple(of: 3) ? 0.95 : 0.45
        case .error:
            return 0.35
        case .stopped:
            return 0.55
        }
    }

    private static func drawStatusBadge(in bounds: CGRect, state: IconState, scale: CGFloat) {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: bounds.minX + x * bounds.width / 22, y: bounds.minY + y * bounds.height / 18)
        }

        func stroke(_ path: NSBezierPath) {
            NSColor.black.setStroke()
            path.lineWidth = 0.95 * scale
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
        }

        switch state {
        case .busy:
            let sweep = NSBezierPath()
            sweep.appendArc(withCenter: point(10.2, 6.75), radius: 0.8 * scale, startAngle: -35, endAngle: 245, clockwise: false)
            stroke(sweep)
        case .degraded:
            let mark = NSBezierPath()
            mark.move(to: point(17.6, 11.4))
            mark.line(to: point(17.6, 13.0))
            stroke(mark)
            NSColor.black.setFill()
            NSBezierPath(ovalIn: CGRect(x: point(17.25, 13.45).x, y: point(17.25, 13.45).y, width: 0.7 * scale, height: 0.7 * scale)).fill()
        case .error:
            let xmark = NSBezierPath()
            xmark.move(to: point(17.0, 11.6))
            xmark.line(to: point(18.2, 12.8))
            xmark.move(to: point(18.2, 11.6))
            xmark.line(to: point(17.0, 12.8))
            stroke(xmark)
        case .stopped, .running:
            break
        }
    }
}
