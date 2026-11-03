"""Emit tiny synthetic ONNX graphs using protobuf wire encoding and stdlib only.

No source images, learned weights, ONNX package or prebuilt graph assets are used.
The real ONNX Runtime parser and operators consume these transient fixtures.
"""
import math
import json
import struct
import sys
from pathlib import Path


def varint(value):
    result = bytearray()
    while value > 127:
        result.append((value & 127) | 128)
        value >>= 7
    result.append(value)
    return bytes(result)


def integer(field, value):
    return varint(field << 3) + varint(value)


def message(field, value):
    value = value.encode() if isinstance(value, str) else value
    return varint((field << 3) | 2) + varint(len(value)) + value


def info(name, dimensions, dtype=1):
    shape = b''.join(message(1, message(2, dim) if isinstance(dim, str) else integer(1, dim)) for dim in dimensions)
    return message(1, name) + message(2, message(1, integer(1, dtype) + message(2, shape)))


def tensor(name, dimensions, values, dtype=1):
    raw = struct.pack('<' + ('f' if dtype == 1 else 'q') * len(values), *values)
    return (b''.join(integer(1, dim) for dim in dimensions) + integer(2, dtype)
            + message(8, name) + message(9, raw))


def node(op, inputs, output, attributes=b''):
    return (b''.join(message(1, name) for name in inputs) + message(2, output)
            + message(4, op) + attributes)


def graph(*, input_name='data', output_name='1333', input_shape=('batch', 3, 112, 112),
          output_shape=(1, 512), input_type=1, output_type=1, constant=None,
          actual_shape=(1, 512)):
    if constant is None:
        # Reduce all input coordinates to a scalar; expanding it means the
        # numerical oracle depends on the actual supplied tensor.
        attr = message(5, message(1, 'keepdims') + integer(3, 0) + integer(20, 2))
        initializers = message(5, tensor('shape', [2], [1, 512], 7))
    else:
        count = math.prod(actual_shape)
        initializers = message(5, tensor('constant', actual_shape, [constant] * count, output_type))
        nodes = node('Identity', ['constant'], output_name)
    # Build node framing separately so protobuf repeated fields retain boundaries.
    if constant is None:
        body = message(1, node('ReduceMean', [input_name], 'mean', attr))
        body += message(1, node('Expand', ['mean', 'shape'], output_name))
    else:
        body = message(1, nodes)
    body += message(2, 'synthetic_contract_fixture') + initializers
    body += message(11, info(input_name, input_shape, input_type))
    body += message(12, info(output_name, output_shape, output_type))
    return integer(1, 7) + message(7, body) + message(8, integer(2, 11))


def generate(destination):
    destination.mkdir(parents=True, exist_ok=True)
    cases = {
        'valid': {}, 'input_name': {'input_name': 'unexpected'},
        'output_name': {'output_name': 'unexpected'},
        'input_shape': {'input_shape': (1, 3, 111, 112)},
        'batch_two': {'input_shape': (2, 3, 112, 112)},
        'input_type': {'input_type': 7, 'constant': 1.0},
        'output_shape': {'output_shape': (1, 511), 'actual_shape': (1, 511), 'constant': 1.0},
        'output_type': {'output_type': 7, 'constant': 1},
        'nan': {'constant': float('nan')}, 'infinity': {'constant': float('inf')},
        'zero': {'constant': 0.0},
    }
    for name, options in cases.items():
        (destination / (name + '.onnx')).write_bytes(graph(**options))
    (destination / 'malformed.onnx').write_bytes(b'not_an_onnx_graph')
    return len(cases) + 1


def generate_vectors(root, destination):
    document = json.loads((root / 'contracts/auraface-aligned-input-v1.vectors.json').read_text())
    rows = []
    for case in document['cases']:
        rows.append('{' + ','.join(json.dumps(case[key]) for key in ('id', 'inputSHA256', 'tensorSHA256')) + '}')
    destination.write_text('const std::array<std::array<const char*, 3>, ' + str(len(rows))
                          + '> common_vectors{{' + ','.join(rows) + '}};\n')
    negative_rows = []
    for case in document['negativeCases']:
        mutation = case['mutation']
        if case['expectedFailure'] != 'invalid_input' or not set(mutation) <= {'width', 'height', 'orientation', 'pixelFormat'}:
            raise ValueError('Unsupported aligned-input negative vector')
        if mutation.get('pixelFormat', 'rgb8') not in {'rgb8', 'gray8'}:
            raise ValueError('Unsupported negative pixel format')
        values = [mutation.get('width', 112), mutation.get('height', 112),
                  mutation.get('orientation', 1), int(mutation.get('pixelFormat') == 'gray8')]
        if any(type(value) is not int or value < 0 for value in values):
            raise ValueError('Invalid negative-vector metadata')
        negative_rows.append('{' + ','.join(str(value) for value in values) + '}')
    with destination.open('a') as stream:
        stream.write('const std::array<std::array<std::int64_t, 4>, ' + str(len(negative_rows))
                     + '> common_negative_vectors{{' + ','.join(negative_rows) + '}};\n')
    baseline = json.loads((root / 'contracts/auraface-baseline-output-v1.json').read_text())
    baseline_path = destination.parent / 'auraface_baseline.inc'
    baseline_path.write_text('const std::array<float, 512> baseline_features{{'
                            + ','.join(str(value) + 'F' for value in baseline['rawFeatures']) + '}};\n'
                            + 'constexpr double baseline_max_error = ' + repr(baseline['maximumAbsoluteFeatureDifference']) + ';\n'
                            + 'constexpr double baseline_min_cosine = ' + repr(baseline['minimumCosine']) + ';\n'
                            + 'const char* baseline_input_sha256 = ' + json.dumps(baseline['inputSHA256']) + ';\n')
    return len(rows)


if __name__ == '__main__':
    print('synthetic_onnx_fixtures=' + str(generate(Path(sys.argv[1]))))
