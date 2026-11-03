"""Offline prompt-contract assembly and conformance checks; never runs a model."""
import argparse
from copy import deepcopy
from datetime import date
import hashlib
import json
import math
from pathlib import Path
import unicodedata

from jsonschema import Draft202012Validator, FormatChecker
from referencing import Registry, Resource

ROOT = Path(__file__).resolve().parents[1]
PROFILE = ROOT / 'profiles/liquid-evidence-review-v2.json'
TEMPORAL = {'motion_parallax', 'highlight_motion', 'replay_motion', 'camera_motion_consistency'}


def encoded(value):
    return json.dumps(value, ensure_ascii=False, allow_nan=False, sort_keys=True,
                      separators=(',', ':')).encode('utf-8')


def digest(data):
    return hashlib.sha256(data).hexdigest()


def strict_load(path):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError('Duplicate JSON key: ' + key)
            result[key] = value
        return result

    def invalid_constant(value):
        raise ValueError('Nonfinite JSON number: ' + value)

    return json.loads(Path(path).read_bytes().decode('utf-8'), object_pairs_hook=pairs,
                      parse_constant=invalid_constant)


def inspect_values(value):
    if isinstance(value, str):
        value.encode('utf-8', errors='strict')
        if any(unicodedata.category(char) in {'Cc', 'Cf', 'Cs'} for char in value):
            raise ValueError('Control character or surrogate in decoded content')
    elif isinstance(value, float) and not math.isfinite(value):
        raise ValueError('Nonfinite number')
    elif isinstance(value, dict):
        for key, item in value.items():
            inspect_values(key)
            inspect_values(item)
    elif isinstance(value, list):
        for item in value:
            inspect_values(item)


def validators():
    registry = Registry()
    schemas = {}
    for path in sorted((ROOT / 'schemas').glob('*.schema.json')):
        schema = strict_load(path)
        Draft202012Validator.check_schema(schema)
        schemas[path.name] = schema
        registry = registry.with_resource(schema['$id'], Resource.from_contents(schema))
    return {name: Draft202012Validator(schema, registry=registry, format_checker=FormatChecker())
            for name, schema in schemas.items()}


def validate_input(value, checks):
    inspect_values(value)
    schema = ('liquid-prompt-input-v2.schema.json' if 'bindings' in value
              else 'liquid-native-prompt-input-v2.schema.json')
    checks[schema].validate(value)
    images = value['images']
    if images[0]['imageId'] != 'Media-1' or images[0]['role'] != 'reference':
        raise ValueError('First image must be the reference in Media-1')
    if images[1]['imageId'] != 'Media-2' or images[1]['role'] != 'selfie':
        raise ValueError('Second image must be the reviewed selfie in Media-2')
    if len({item['imageId'] for item in images}) != len(images):
        raise ValueError('Duplicate image role ID')
    for index, item in enumerate(images[2:], start=3):
        if item['imageId'] != 'Media-' + str(index) or item['role'] != 'selfie_sequence':
            raise ValueError('Additional frames must retain ordered selfie_sequence roles')
    if any(item['width'] * item['height'] > 8388608 for item in images):
        raise ValueError('Image exceeds the pinned pixel budget')
    bindings = value.get('bindings', {role: image for role, image in zip(('reference', 'selfie'), images)})
    for role, image in zip(('reference', 'selfie'), images):
        if image['sha256'] != bindings[role]['sha256']:
            raise ValueError('Original image binding mismatch')
    aura = value['context']['aura']
    if aura['status'] == 'available':
        if any(aura[role + 'SHA256'] != bindings[role]['sha256'] for role in ('reference', 'selfie')):
            raise ValueError('Aura result belongs to another image pair')
    age = value['context']['age']
    if age['status'] == 'available':
        born = date.fromisoformat(age['dateOfBirth'])
        for date_key, age_key in [('selfieCaptureDate', 'expectedAgeAtSelfieCapture'),
                                  ('referencePhotoDate', 'expectedAgeAtReferencePhoto')]:
            when = age[date_key]
            if when is None:
                if age[age_key] is not None:
                    raise ValueError('Unknown photo date cannot carry an expected age')
                continue
            when = date.fromisoformat(when)
            expected = when.year - born.year - ((when.month, when.day) < (born.month, born.day))
            if expected < 0 or age[age_key] != expected:
                raise ValueError('Expected age must agree with admitted DOB and capture date')
    capture = value['context']['capture']
    if capture['mode'] == 'still':
        if len(images) != 2 or capture['sequenceSHA256'] is not None or capture['clockDomain'] is not None:
            raise ValueError('Still mode cannot imply a frame sequence')
    else:
        times = [item['timestampSeconds'] for item in images[1:]]
        if len(images) < 3 or not capture['sequenceSHA256'] or not capture['clockDomain']:
            raise ValueError('Sequence needs ordered frames, digest and clock domain')
        if any(value is None for value in times) or any(a >= b for a, b in zip(times, times[1:])):
            raise ValueError('Frame times must increase strictly in one clock domain')
    for name in ('motion', 'depth'):
        signal = capture[name]
        if signal['status'] == 'available':
            if capture['mode'] != 'sequence' or signal['sequenceSHA256'] != capture['sequenceSHA256']:
                raise ValueError('Signal summary must bind the admitted sequence')
    measurements = capture['measurements']
    if measurements['status'] == 'available':
        frame_time = measurements['frameTimestampSeconds']
        if measurements['imageSHA256'] != images[1]['sha256'] or frame_time != images[1]['timestampSeconds']:
            raise ValueError('Capture measurement belongs to another selfie frame')
        depth = measurements['depth']
        if depth is not None:
            if depth['imageTimestampSeconds'] != frame_time or depth['depthTimestampSeconds'] > frame_time:
                raise ValueError('Depth measurement is not aligned to the selfie')
            if depth['sampleCount'] > depth['mapWidth'] * depth['mapHeight']:
                raise ValueError('Depth sample count exceeds its map')
            quality = measurements['quality']
            frame_age = quality['frameAgeAtAdmissionSeconds'] if quality else None
            if frame_age is not None and not math.isclose(depth['ageAtAdmissionSeconds'], frame_age + frame_time - depth['depthTimestampSeconds'], abs_tol=1e-6):
                raise ValueError('Depth age differs from frame timing')
        blink = measurements['blink']
        if blink is not None:
            quality = measurements['quality']
            frame_age = quality['frameAgeAtAdmissionSeconds'] if quality else None
            if blink['completedAtSeconds'] > frame_time:
                raise ValueError('Blink completed after the captured frame')
            if frame_age is not None and not math.isclose(blink['ageSeconds'], frame_time + frame_age - blink['completedAtSeconds'], abs_tol=1e-6):
                raise ValueError('Blink age differs from admission timing')
        motion = measurements['motion']
        if motion is not None:
            start, end = motion['windowStartTimestampSeconds'], motion['windowEndTimestampSeconds']
            if motion['frameTimestampSeconds'] != frame_time or not start < end <= frame_time:
                raise ValueError('Motion window does not precede this selfie frame')
            if frame_time - end > 0.2 or not math.isclose(motion['summary']['durationSeconds'], end - start, abs_tol=1e-6):
                raise ValueError('Motion window is stale or its duration is inconsistent')
    return value


def validate_output(value, request, checks):
    inspect_values(value)
    checks['liquid-prompt-output-v2.schema.json'].validate(value)
    for role in ('reference', 'selfie'):
        interval = value[role]['apparentAge']['rangeYears']
        if interval is not None and interval[0] > interval[1]:
            raise ValueError('Apparent-age range is reversed')
    if request['context']['aura']['status'] != 'available' and value['auraReview']['relationship'] != 'not_assessable':
        raise ValueError('Unavailable Aura result cannot be cross-checked')
    if request['context']['age']['status'] != 'available' and value['ageReview']['relationship'] != 'not_assessable':
        raise ValueError('Unavailable DOB context cannot be cross-checked')
    indicators = value['captureReview']['indicators']
    if len({item['indicator'] for item in indicators}) != len(indicators):
        raise ValueError('Duplicate indicator')
    capture = request['context']['capture']
    images = {item['imageId']: item for item in request['images']}
    for item in indicators:
        if any(key not in images or images[key]['role'] == 'reference' for key in item['sourceImageIds']):
            raise ValueError('Capture indicators must reference supplied selfie evidence')
        name, status = item['indicator'], item['status']
        if name in TEMPORAL and status != 'not_observable':
            if capture['mode'] != 'sequence' or len(item['sourceImageIds']) < 2:
                raise ValueError('Temporal finding requires multiple admitted selfie frames')
        if name == 'camera_motion_consistency' and status != 'not_observable':
            if capture['motion']['status'] != 'available':
                raise ValueError('Camera-motion finding requires aligned motion evidence')
        if name == 'depth_consistency' and status != 'not_observable':
            measurements = capture['measurements']
            has_static_depth = measurements['status'] == 'available' and measurements['depth'] is not None
            if capture['depth']['status'] != 'available' and not has_static_depth:
                raise ValueError('Depth finding requires admitted depth evidence')
    return value


def load_profile():
    profile = strict_load(PROFILE)
    for item in profile['resources'].values():
        relative = Path(item['path'])
        if relative.is_absolute() or '..' in relative.parts:
            raise ValueError('Profile path must stay in contracts')
        path = ROOT / relative
        if any(part.is_symlink() for part in [path, *path.parents] if part != ROOT.parent) or digest(path.read_bytes()) != item['sha256']:
            raise ValueError('Profile resource digest mismatch: ' + str(relative))
    return profile


def model_context(request):
    """Exclude bookkeeping digests from tokens; preserve the substantive context."""
    value = deepcopy(request['context'])
    for name in ('resultSHA256', 'referenceSHA256', 'selfieSHA256'):
        value['aura'].pop(name, None)
    for name in ('dobEvidenceId', 'credentialEvidenceId'):
        value['age'].pop(name, None)
    for name in ('motion', 'depth'):
        for key in ('sourceSHA256', 'sequenceSHA256'):
            value['capture'][name].pop(key, None)
    value['capture'].pop('sequenceSHA256', None)
    measurements = value['capture']['measurements']
    for key in ('sourceSHA256', 'imageSHA256'):
        measurements.pop(key, None)
    if measurements.get('depth') is not None:
        measurements['depth'].pop('sourceSHA256', None)
    if measurements.get('motion') is not None:
        measurements['motion'].pop('sourceSHA256', None)
        measurements['motion']['summary'].pop('rawWindowSHA256', None)
    value['images'] = [{key: item[key] for key in ('imageId', 'role', 'width', 'height', 'timestampSeconds')}
                       for item in request['images']]
    return value


def assemble(request):
    profile = load_profile()
    checks = validators()
    validate_input(request, checks)
    resources = profile['resources']
    schema = strict_load(ROOT / resources['outputSchema']['path'])
    examples = strict_load(ROOT / resources['examples']['path'])
    task = (ROOT / resources['prompt']['path']).read_text()
    messages = [{'role': 'system', 'content': task + '\nExpected JSON Schema:\n' + encoded(schema).decode()}]
    for case in examples['examples']:
        validate_input(case['input'], checks)
        validate_output(case['output'], case['input'], checks)
        demo = {'kind': 'format_example_only', 'hypotheticalImages': case['imageDescriptions'],
                'context': model_context(case['input'])}
        messages.append({'role': 'user', 'content': encoded(demo).decode()})
        messages.append({'role': 'assistant', 'content': encoded(case['output']).decode()})
    content = []
    for item in request['images']:
        content += [{'type': 'text', 'text': '[' + item['imageId'] + ']'},
                    {'type': 'image_ref', 'imageId': item['imageId'], 'sha256': item['sha256']}]
    content.append({'type': 'text', 'text': 'CURRENT EVIDENCE\n' + encoded(model_context(request)).decode()})
    messages.append({'role': 'user', 'content': content})
    if len(encoded(messages)) > profile['limits']['maximumInputBytes']:
        raise ValueError('Prompt bundle exceeds input byte ceiling')
    return {'profileId': profile['profileId'], 'profileSHA256': digest(PROFILE.read_bytes()),
            'inputSHA256': digest(encoded(request)), 'messagesSHA256': digest(encoded(messages)),
            'responseSchema': schema, 'generation': profile['generation'], 'messages': messages}


def check():
    profile = load_profile()
    checks = validators()
    cases = strict_load(ROOT / profile['resources']['examples']['path'])['examples']
    for case in cases:
        validate_input(case['input'], checks)
        validate_output(case['output'], case['input'], checks)
        assemble(case['input'])
    print('PASS schemas, resource pins and ' + str(len(cases)) + ' balanced examples/assembled packets')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.input:
        packet = assemble(strict_load(args.input))
        if not args.output:
            parser.error('--input requires --output')
        args.output.write_bytes(encoded(packet) + b'\n')
    else:
        check()
