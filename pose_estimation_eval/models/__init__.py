from pose_estimation_eval.models.base import Keypoint, PoseModel, PoseResult
from pose_estimation_eval.models.mediapipe_blazepose import MediaPipeBlazePoseModel
from pose_estimation_eval.models.movenet import MoveNetModel
from pose_estimation_eval.models.rtmpose import RTMPoseModel
from pose_estimation_eval.models.yolo_pose import YOLOPoseModel

ALL_MODELS: dict[str, type[PoseModel]] = {
    "movenet_lightning": MoveNetModel,
    "mediapipe_blazepose": MediaPipeBlazePoseModel,
    "yolo11n_pose": YOLOPoseModel,
    "rtmpose": RTMPoseModel,
}

__all__ = [
    "PoseModel",
    "PoseResult",
    "Keypoint",
    "MoveNetModel",
    "MediaPipeBlazePoseModel",
    "YOLOPoseModel",
    "RTMPoseModel",
    "ALL_MODELS",
]
