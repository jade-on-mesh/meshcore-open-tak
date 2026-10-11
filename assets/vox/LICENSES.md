# Bundled VOX models

- `face_yunet_2023mar.onnx`: YuNet face detector (OpenCV Zoo), MIT License,
  Copyright (c) 2020 Shiqi Yu. https://github.com/opencv/opencv_zoo
- `text_ppocrv3_det.onnx`: PaddleOCR PP-OCRv3 text detection model,
  Apache License 2.0, Copyright (c) PaddlePaddle Authors.
  https://github.com/PaddlePaddle/PaddleOCR (ONNX export via RapidOCR)

Both are used only on the sending phone, to find text and faces so the image
encoder can spend more of its bytes there. They never alter the picture the
receiver sees beyond softening the unimportant parts before encoding.
