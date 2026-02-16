import AVFoundation
import UIKit
import Vision

final class SkeletonOverlayView: UIView {
    var observations: [BodyObservation] = [] {
        didSet { setNeedsDisplay() }
    }

    weak var previewLayer: AVCaptureVideoPreviewLayer?

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

    private let skeletonColor = UIColor.green
    private let centroidColor = UIColor.yellow
    private let jointRadius: CGFloat = 4
    private let centroidRadius: CGFloat = 7
    private let lineWidth: CGFloat = 2

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        for body in observations {
            drawSkeleton(body: body, in: ctx)
            drawCentroid(body: body, in: ctx)
        }
    }

    private func drawSkeleton(body: BodyObservation, in ctx: CGContext) {
        let joints = body.jointPoints

        ctx.setStrokeColor(skeletonColor.cgColor)
        ctx.setLineWidth(lineWidth)

        for (jointA, jointB) in jointConnections {
            guard let pointA = joints[jointA], let pointB = joints[jointB] else { continue }
            let screenA = convertToScreen(pointA)
            let screenB = convertToScreen(pointB)
            ctx.move(to: screenA)
            ctx.addLine(to: screenB)
            ctx.strokePath()
        }

        ctx.setFillColor(skeletonColor.cgColor)
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

    private func drawCentroid(body: BodyObservation, in ctx: CGContext) {
        let screenPoint = convertToScreen(body.torsoCentroid)

        ctx.setFillColor(centroidColor.cgColor)
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

    private func convertToScreen(_ point: CGPoint) -> CGPoint {
        // point is in normalized coordinates (0-1) with top-left origin
        // (Y was flipped from Vision's bottom-left in PoseEstimator)
        //
        // AVCaptureVideoPreviewLayer.layerPointConverted(fromCaptureDevicePoint:)
        // expects normalized coords with top-left origin — exactly what we have.
        // It accounts for videoGravity (.resizeAspectFill cropping) automatically.
        if let layer = previewLayer {
            return layer.layerPointConverted(fromCaptureDevicePoint: point)
        }
        // Fallback if no preview layer reference
        return CGPoint(x: point.x * bounds.width, y: point.y * bounds.height)
    }
}
