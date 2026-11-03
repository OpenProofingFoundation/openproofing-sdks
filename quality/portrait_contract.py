"""Reference oracle for synthetic portrait pixels/bindings, not a native processing engine."""
import copy
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
DIGEST = re.compile(r'[0-9a-f]{64}')
IDENTIFIER = re.compile(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}')
PIXEL_FIELDS = {'width', 'height', 'format', 'rowStrideBytes', 'byteLength', 'sha256', 'orientation'}


def validate_pixels(value, payload, profile):
    if not isinstance(value, dict) or set(value) != PIXEL_FIELDS:
        raise ValueError('invalid_schema')
    if not isinstance(value['format'], str) or value['format'] not in profile['pixelFormats']:
        raise ValueError('unsupported_format')
    counts = [value[name] for name in ('width', 'height', 'rowStrideBytes', 'byteLength', 'orientation')]
    if any(type(count) is not int or count <= 0 or count > profile['metadataIntegerRange']['maximum'] for count in counts) or value['orientation'] > 8:
        raise ValueError('invalid_pixels')
    width, height = value['width'], value['height']
    if max(width, height) > profile['maxDimension'] or width * height > profile['maxPixels']:
        raise ValueError('resource_limit')
    row = width * profile['pixelFormats'][value['format']]
    size = row * height
    if size > profile['maxBytes']:
        raise ValueError('resource_limit')
    if value['rowStrideBytes'] != row or value['byteLength'] != size or len(payload) != size:
        raise ValueError('invalid_pixels')
    if not isinstance(value['sha256'], str) or DIGEST.fullmatch(value['sha256']) is None:
        raise ValueError('invalid_schema')
    if hashlib.sha256(payload).hexdigest() != value['sha256']:
        raise ValueError('integrity_failure')


def validate_binding(expected, completion, profile):
    for value in (expected, completion):
        if not isinstance(value, dict) or set(value) != set(profile['bindingFields']):
            raise ValueError('invalid_schema')
        for name, content in value.items():
            pattern = DIGEST if name.endswith('SHA256') else IDENTIFIER
            if not isinstance(content, str) or pattern.fullmatch(content) is None:
                raise ValueError('invalid_schema')
    if expected != completion:
        raise ValueError('binding_mismatch')


def apply_overrides(base, vector):
    value = copy.deepcopy(base)
    value.update(vector.get('overrides', {}))
    for name in vector.get('removeFields', []):
        value.pop(name)
    return value


def evaluate_vector(vector, fixtures, profile):
    try:
        if vector['kind'] == 'pixels':
            payload = bytes.fromhex(vector.get('payloadHex', fixtures['pixelBase']['payloadHex']))
            validate_pixels(apply_overrides(fixtures['pixelBase']['descriptor'], vector), payload, profile)
        elif vector['kind'] == 'binding':
            validate_binding(fixtures['bindingBase'], apply_overrides(fixtures['bindingBase'], vector), profile)
        else:
            raise ValueError('invalid_schema')
    except ValueError as error:
        reason = str(error)
        if reason not in profile['failures']:
            raise
        return reason
    return 'valid'


def check(root=ROOT):
    profile = json.loads((root/'contracts/portrait-selfie-v1.json').read_text())
    fixtures = json.loads((root/'contracts/portrait-selfie-v1.vectors.json').read_text())
    vectors = fixtures['vectors']
    if not vectors or len({v['id'] for v in vectors}) != len(vectors):
        raise ValueError('Empty or duplicate portrait fixture inventory')
    for vector in vectors:
        actual = evaluate_vector(vector, fixtures, profile)
        if actual != vector['expect']:
            raise ValueError(vector['id']+': expected '+vector['expect']+'; observed '+actual)
    return len(vectors)


if __name__ == '__main__':
    print('PASS portrait reference vectors: '+str(check())+'; native adapters remain separate')
