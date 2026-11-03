"""Generate C++ case data from the authoritative shared synthetic JSON inventory."""
import json
from pathlib import Path


def scalar(value):
    if isinstance(value, bool):
        return 'true' if value else 'false'
    if isinstance(value, int):
        if -(2**63) <= value < 2**63:
            return 'std::int64_t{'+str(value)+'}'
        if 0 <= value < 2**64:
            return 'std::uint64_t{'+str(value)+'ULL}'
        # Larger JSON integers remain oversized numeric metadata, never strings.
        return 'std::uint64_t{18446744073709551615ULL}'
    if isinstance(value, float):
        return 'double{'+repr(value)+'}'
    if isinstance(value, str):
        # JSON escaping is valid for the synthetic ASCII fixtures; reject rather
        # than silently emit nonportable C++ unicode or control characters.
        if not value.isascii():
            return 'std::string{'+json.dumps(value, ensure_ascii=True)+'}'
        return 'std::string{'+json.dumps(value)+'}'
    return 'std::monostate{}'


def fields(value):
    return 'Fields{'+','.join('{'+json.dumps(key)+','+scalar(content)+'}' for key, content in value.items())+'}'


def generate(root, destination):
    fixture = json.loads((root/'contracts/portrait-selfie-v1.vectors.json').read_text())
    lines = ['// Generated transiently from shared fixtures; do not commit.',
             'const Fields base_binding = '+fields(fixture['bindingBase'])+';',
             'const Fields base_pixels = '+fields(fixture['pixelBase']['descriptor'])+';',
             'const std::vector<std::byte> base_payload = decode_hex('+json.dumps(fixture['pixelBase']['payloadHex'])+');',
             'void shared_vectors() {']
    for vector in fixture['vectors']:
        base = fixture['pixelBase']['descriptor'] if vector['kind'] == 'pixels' else fixture['bindingBase']
        value = dict(base)
        value.update(vector.get('overrides', {}))
        for key in vector.get('removeFields', []):
            value.pop(key, None)
        arguments = [json.dumps(vector['id']), fields(value)]
        if vector['kind'] == 'pixels':
            arguments.append('decode_hex('+json.dumps(vector.get('payloadHex', fixture['pixelBase']['payloadHex']))+')')
        arguments.append(json.dumps(vector['expect']))
        lines.append('    '+('pixel_case' if vector['kind'] == 'pixels' else 'binding_case')+'('+', '.join(arguments)+');')
    lines.append('}')
    destination.write_text('\n'.join(lines)+'\n')
    return len(fixture['vectors'])


def number(value, scalar_type='double'):
    if isinstance(value, str):
        special = {'nan': 'quiet_NaN()', 'positive_infinity': 'infinity()',
                   'negative_infinity': 'infinity()'}
        sign = '-' if value == 'negative_infinity' else ''
        return sign+'std::numeric_limits<'+scalar_type+'>::'+special[value]
    return 'static_cast<'+scalar_type+'>('+repr(value)+')'


def embedding_space(value):
    return 'EmbeddingSpace('+json.dumps(value['artifactManifestSHA256'])+', EmbeddingDomain::'+value['domain']+', '+str(value['dimensions'])+', '+number(value['minimumNorm'])+')'


def features(value):
    return 'std::vector<float>{'+','.join(number(item, 'float') for item in value)+'}'


def generate_math(root, destination):
    fixture = json.loads((root/'contracts/embedding-math-v1.vectors.json').read_text())
    lines = ['// Generated transiently from shared math fixtures.', 'void shared_math_vectors() {']
    for vector in fixture['vectors']:
        left_space = dict(fixture['baseSpace'])
        left_space.update(vector.get('spaceOverrides', {}))
        right_space = dict(left_space)
        right_space.update(vector.get('rightSpaceOverrides', {}))
        expected = vector['expect']
        lines.extend([
            '    expect('+json.dumps(vector['id'])+', '+json.dumps(expected.get('failure', 'valid'))+', [&] {',
            '        const auto left = embedding('+features(vector['leftFeatures'])+', '+embedding_space(left_space)+');'
        ])
        if vector['operation'] == 'compare':
            lines.extend([
                '        const auto right = embedding('+features(vector['rightFeatures'])+', '+embedding_space(right_space)+');',
                '        const auto cosine = left.cosine(right);'
            ])
            if 'failure' not in expected:
                lines.extend([
                    '        near(cosine, '+number(expected['cosine'])+', '+number(fixture['absoluteTolerance'])+');',
                    '        near(left.angular_distance(right), '+number(expected['angularDistanceRadians'])+', '+number(fixture['absoluteTolerance'])+');'
                ])
            else:
                lines.append('        static_cast<void>(cosine);')
        elif 'failure' not in expected:
            lines.extend([
                '        check(std::abs(left.raw_norm() - '+number(expected['norm'])+') <= std::abs('+number(expected['norm'])+') * '+number(fixture['normRelativeTolerance'])+');',
                '        check(left.raw_norm() > 0);',
                '        check(left.components().size() == '+str(len(expected['components']))+');'
            ])
            for index, value in enumerate(expected['components']):
                lines.append('        near(left.components()['+str(index)+'], '+number(value)+', '+number(fixture['absoluteTolerance'])+');')
        lines.append('    });')
    lines.append('}')
    destination.write_text('\n'.join(lines)+'\n')
    return len(fixture['vectors'])
