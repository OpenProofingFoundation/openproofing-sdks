#!/usr/bin/env python3
"""Synthetic toolchain check: one optimizer step, ONNX parity, Core ML FP16 parity."""
import argparse
import hashlib
import importlib.metadata
import json
from pathlib import Path
import platform
import sys
import time
from data import external_directory

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--workdir',required=True,type=Path)
    args=parser.parse_args();root=external_directory(args.workdir)
    output=root/'runs'/time.strftime('toolchain-%Y%m%d-%H%M%S');output.mkdir(parents=True)
    import numpy as np
    import torch
    import onnx
    import onnxruntime as ort
    import coremltools as ct
    torch.manual_seed(20261016);np.random.seed(20261016)
    backend='mps' if torch.backends.mps.is_available() else 'cpu'
    model=torch.nn.Sequential(torch.nn.Conv2d(3,8,3,padding=1),torch.nn.ReLU(),torch.nn.AdaptiveAvgPool2d((1,1)),torch.nn.Flatten(),torch.nn.Linear(8,512)).to(backend)
    inputs=torch.rand(2,3,112,112,device=backend)
    optimizer=torch.optim.SGD(model.parameters(),lr=0.001,momentum=0.0,weight_decay=0.0)
    before=model[-1].weight.detach().clone()
    loss=model(inputs).square().mean();loss.backward();optimizer.step()
    if not bool(torch.isfinite(loss)) or torch.equal(before,model[-1].weight):raise RuntimeError('Training step failed')
    if backend=='mps':torch.mps.synchronize()
    model=model.cpu().eval();sample=inputs[:1].cpu()
    with torch.no_grad():reference=model(sample).numpy()
    path=output/'synthetic.onnx'
    torch.onnx.export(model,sample,str(path),input_names=['face'],output_names=['embedding'],opset_version=17,dynamo=False)
    onnx.checker.check_model(onnx.load(path))
    session=ort.InferenceSession(str(path),providers=['CPUExecutionProvider'])
    actual=session.run(['embedding'],{'face':sample.numpy()})[0]
    np.testing.assert_allclose(reference,actual,rtol=1e-4,atol=1e-5)
    traced=torch.jit.trace(model,sample)
    coreml=ct.convert(traced,inputs=[ct.TensorType(name='face',shape=(1,3,112,112))],outputs=[ct.TensorType(name='embedding')],convert_to='mlprogram',minimum_deployment_target=ct.target.iOS18,compute_precision=ct.precision.FLOAT16,compute_units=ct.ComputeUnit.CPU_ONLY)
    package=output/'synthetic.mlpackage';coreml.save(str(package))
    converted=coreml.predict({'face':sample.numpy()})['embedding']
    np.testing.assert_allclose(reference,converted,rtol=0.01,atol=0.002)
    versions={name:importlib.metadata.version(name) for name in ['torch','torchvision','numpy','onnx','onnxruntime','coremltools','pillow','pillow-heif','safetensors','cmake','ninja']}
    result={'status':'passed','scope':'synthetic convolution network only; no face model or biometric performance claim','python':platform.python_version(),'machine':platform.machine(),'trainingBackend':backend,'optimizerStep':True,'onnxRuntimeProvider':'CPUExecutionProvider','onnxMaxAbsoluteError':float(np.max(np.abs(reference-actual))),'coremlComputeUnits':'CPU_ONLY','coremlPrecision':'FLOAT16','coremlMaxAbsoluteError':float(np.max(np.abs(reference-converted))),'outputShape':list(reference.shape),'versions':versions,'onnxSHA256':hashlib.sha256(path.read_bytes()).hexdigest()}
    (output/'receipt.json').write_text(json.dumps(result,indent=2)+'\n')
    (root/'latest-toolchain-receipt.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))
if __name__=='__main__':main()
