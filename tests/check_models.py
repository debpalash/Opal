import onnxruntime as ort
det = ort.InferenceSession('models/ppocr_det.onnx')
print('DET inputs:', [(i.name, i.shape) for i in det.get_inputs()])
print('DET outputs:', [(o.name, o.shape) for o in det.get_outputs()])
rec = ort.InferenceSession('models/ppocr_rec.onnx')
print('REC inputs:', [(i.name, i.shape) for i in rec.get_inputs()])
print('REC outputs:', [(o.name, o.shape) for o in rec.get_outputs()])
