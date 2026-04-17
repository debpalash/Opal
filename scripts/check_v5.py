import onnx
m = onnx.load('models/ppocr_det_v5.onnx')
for i in m.graph.input:
    dims = [d.dim_value or d.dim_param for d in i.type.tensor_type.shape.dim]
    print(f"DET input: {i.name} {dims}")
for o in m.graph.output:
    dims = [d.dim_value or d.dim_param for d in o.type.tensor_type.shape.dim]
    print(f"DET output: {o.name} {dims}")

m2 = onnx.load('models/ppocr_rec_v5.onnx')
for i in m2.graph.input:
    dims = [d.dim_value or d.dim_param for d in i.type.tensor_type.shape.dim]
    print(f"REC input: {i.name} {dims}")
for o in m2.graph.output:
    dims = [d.dim_value or d.dim_param for d in o.type.tensor_type.shape.dim]
    print(f"REC output: {o.name} {dims}")

with open('models/en_dict_v5.txt') as f:
    lines = f.readlines()
    print(f"Dict: {len(lines)} entries")
