import AVFoundation
import UIKit
import Vision

final class SkeletonOverlayView: UIView {
    var trackingResult: BodyTrackingResult? {
        didSet { setNeedsDisplay() }
    }

    var stateMachineDebug: StateMachineDebugInfo?
    var captureFPS: Double = 0
    var detectionFlash: Bool = false {
        didSet {
            if detectionFlash {
                triggerFlash()
            }
        }
    }

    weak var previewLayer: AVCaptureVideoPreviewLayer?

    private let flashBorderLayer = CAShapeLayer()

    private let jointConnections: [(VNHumanBodyPoseObservation.JointName, VNHumanBodyPoseObservation.JointName)] = [
        (.nose, .neck),
        (.neck, .root),
        (.neck, .leftShoulder),
        (.leftShoulder, .leftElbow),
        (.leftElbow, .leftWrist),
        (.neck, .rightShoulder),
        (.rightShoulder, .rightElbow),
        (.rightElbow, .rightWrist),
        (.root, .leftHip),
        (.leftHip, .leftKnee),
        (.leftKnee, .leftAnkle),
        (.root, .rightHip),
        (.rightHip, .rightKnee),
        (.rightKnee, .rightAnkle),
    ]

    private let defaultSkeletonColor = UIColor.green
    private let dominantSkeletonColor = UIColor.cyan
    private let centroidColor = UIColor.yellow
    private let dominantCentroidColor = UIColor.orange
    private let velocityLineColor = UIColor.yellow.withAlphaComponent(0.6)
    private let jointRadius: CGFloat = 4
    private let centroidRadius: CGFloat = 7
    private let lineWidth: CGFloat = 2

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = .clear
        isUserInteractionEnabled = false
        flashBorderLayer.fillColor = nil
        flashBorderLayer.strokeColor = UIColor.red.cgColor
        flashBorderLayer.lineWidth = 6
        flashBorderLayer.opacity = 0
        layer.addSublayer(flashBorderLayer)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        flashBorderLayer.frame = bounds
        flashBorderLayer.path = UIBezierPath(rect: bounds).cgPath
    }

    private func triggerFlash() {
        flashBorderLayer.removeAllAnimations()
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 1.0
        anim.toValue = 0.0
        anim.duration = 0.5
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        flashBorderLayer.add(anim, forKey: "flash")
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(),
              let result = trackingResult else { return }

        for body in result.trackedBodies {
            let isDominant = body.id == result.dominantMoverID
            let skeletonColor = isDominant ? dominantSkeletonColor : defaultSkeletonColor
            drawSkeleton(body: body, color: skeletonColor, in: ctx)
            drawVelocityTrail(body: body, in: ctx)
            drawCentroid(body: body, isDominant: isDominant, in: ctx)
        }

        drawDebugInfo(result: result, in: ctx)
    }

    private func drawSkeleton(body: TrackedBody, color: UIColor, in ctx: CGContext) {
        let joints = body.jointPoints

        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(lineWidth)

        for (jointA, jointB) in jointConnections {
            guard let pointA = joints[jointA], let pointB = joints[jointB] else { continue }
            let screenA = convertToScreen(pointA)
            let screenB = convertToScreen(pointB)
            ctx.move(to: screenA)
            ctx.addLine(to: screenB)
            ctx.strokePath()
        }

        ctx.setFillColor(color.cgColor)
        for (_, point) in joints {
            let screenPoint = convertToScreen(point)
            let dotRect = CGRect(
                x: screenPoint.x - jointRadius,
                y: screenPoint.y - jointRadius,
                width: jointRadius * 2,
                height: jointRadius * 2
            )
            ctx.fillEllipse(in: dotRect)
        }
    }

    private func drawVelocityTrail(body: TrackedBody, in ctx: CGContext) {
        let history = body.centroidHistory
        guard history.count >= 2 else { return }

        ctx.setStrokeColor(velocityLineColor.cgColor)
        ctx.setLineWidth(2.0)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        let first = convertToScreen(history[0])
        ctx.move(to: first)
        for i in 1..<history.count {
            let point = convertToScreen(history[i])
            ctx.addLine(to: point)
        }
        ctx.strokePath()
    }

    private func drawCentroid(body: TrackedBody, isDominant: Bool, in ctx: CGContext) {
        let screenPoint = convertToScreen(body.centroid)
        let color = isDominant ? dominantCentroidColor : centroidColor

        ctx.setFillColor(color.cgColor)
        let dotRect = CGRect(
            x: screenPoint.x - centroidRadius,
            y: screenPoint.y - centroidRadius,
            width: centroidRadius * 2,
            height: centroidRadius * 2
        )
        ctx.fillEllipse(in: dotRect)

        ctx.setStrokeColor(UIColor.black.cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: dotRect)
    }

    private func drawDebugInfo(result: BodyTrackingResult, in ctx: CGContext) {
        let bodyCount = result.trackedBodies.count
        let dominant = result.trackedBodies.first { $0.id == result.dominantMoverID }

        var lines: [String] = []

        // State machine state
        if let debug = stateMachineDebug {
            lines.append("State: \(debug.state.rawValue)")
        } else {
            lines.append("State: ---")
        }

        lines.append("Bodies: \(bodyCount)")

        if let dom = dominant {
            lines.append(String(format: "H vel: %.3f u/s", dom.horizontalVelocity))
            lines.append(String(format: "V vel: %.3f u/s", dom.verticalVelocity))
        } else {
            lines.append("H vel: ---")
            lines.append("V vel: ---")
        }

        // Thresholds
        if let debug = stateMachineDebug {
            let t = debug.thresholds
            lines.append(String(format: "Thresh H: %.2f  V up: %.2f", t.approachHorizontalVelocity, t.ascendingVerticalVelocity))
            lines.append(String(format: "Thresh V dn: %.2f  Land: %.2f", t.descendingVerticalVelocity, t.landingVerticalMagnitude))
        }

        // Measured FPS
        lines.append(String(format: "Capture FPS: %.1f", captureFPS))
        if let debug = stateMachineDebug, debug.poseFramesProcessed > 1 {
            let elapsed = CACurrentMediaTime() - debug.poseStartTime
            if elapsed > 0 {
                let measuredFPS = Double(debug.poseFramesProcessed) / elapsed
                lines.append(String(format: "Pose FPS: %.1f", measuredFPS))
            }
        }

        let text = lines.joined(separator: "\n") as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: 14, weight: .medium),
            .foregroundColor: UIColor.white,
        ]

        let padding: CGFloat = 12
        let textSize = text.boundingRect(
            with: CGSize(width: bounds.width - padding * 2, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            attributes: attrs,
            context: nil
        ).size

        let textOrigin = CGPoint(x: padding, y: padding)
        let bgRect = CGRect(
            x: textOrigin.x - 4,
            y: textOrigin.y - 2,
            width: textSize.width + 8,
            height: textSize.height + 4
        )

        ctx.saveGState()
        ctx.setFillColor(UIColor.black.withAlphaComponent(0.6).cgColor)
        ctx.fill(bgRect)
        ctx.restoreGState()

        text.draw(in: CGRect(origin: textOrigin, size: textSize), withAttributes: attrs)
    }

    private func convertToScreen(_ point: CGPoint) -> CGPoint {
        if let layer = previewLayer {
            return layer.layerPointConverted(fromCaptureDevicePoint: point)
        }
        return CGPoint(x: point.x * bounds.width, y: point.y * bounds.height)
    }
}
