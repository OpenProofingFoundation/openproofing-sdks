#!/usr/bin/env python3
"""Pinned JSONC parser/schema subset v1 and deterministic native resource compiler.

No third-party packages are required. Unsupported schema keywords fail closed.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parent
VERSION = "kenshiki-design-generator/1;jsonc/1;schema-subset/1"
SWIFT_CASE = '    case '


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Duplicate key: {key}")
        result[key] = value
    return result


def _comment_end(source, index):
    if source.startswith("//", index):
        following = source.find("\n", index)
        return len(source) if following == -1 else following
    if source.startswith("/*", index):
        following = source.find("*/", index + 2)
        if following == -1:
            raise ValueError("Unterminated JSONC comment")
        return following + 2
    return None


def _without_comments(source):
    output = list(source)
    index = 0
    while index < len(source):
        if source[index] == '"':
            _, index = json.decoder.scanstring(source, index + 1)
            continue
        end = _comment_end(source, index)
        if end is None:
            index += 1
            continue
        output[index:end] = re.sub(r'[^\n]', ' ', source[index:end])
        index = end
    return ''.join(output)


def parse_jsonc(source):
    """Strip comments/trailing commas while preserving quoted content and positions."""
    stripped = _without_comments(source)
    output = list(stripped)
    index = 0
    while index < len(stripped):
        if stripped[index] == '"':
            _, index = json.decoder.scanstring(stripped, index + 1)
            continue
        if stripped[index] == ',':
            following = index + 1
            while following < len(stripped) and stripped[following].isspace():
                following += 1
            if following < len(stripped) and stripped[following] in '}]':
                output[index] = ' '
        index += 1
    return json.loads("".join(output), object_pairs_hook=unique_object,
                      parse_constant=_reject_constant)


def _reject_constant(value):
    raise ValueError(f'Non-finite constant: {value}')


def _validate_object(value, schema, path, depth, root_schema, references):
    properties = schema.get('properties', {})
    missing = set(schema.get('required', [])) - value.keys()
    unknown = value.keys() - properties.keys()
    if missing or (schema.get('additionalProperties') is False and unknown):
        raise ValueError(f"{path}: missing {sorted(missing)}; unknown {sorted(unknown)}")
    for key in value.keys() & properties.keys():
        validate(value[key], properties[key], f"{path}.{key}", depth + 1, root_schema, references)


def _validate_array(value, schema, path, depth, root_schema, references):
    if not schema.get('minItems', 0) <= len(value) <= schema.get('maxItems', 10000):
        raise ValueError(f"{path}: invalid item count")
    if 'items' in schema:
        for index, item in enumerate(value):
            validate(item, schema['items'], f"{path}[{index}]", depth + 1, root_schema, references)


def _validate_scalar(value, schema, path):
    if type(value) is int:
        if not schema.get('minimum', value) <= value <= schema.get('maximum', value):
            raise ValueError(f"{path}: out of range")
    if isinstance(value, str):
        if not schema.get('minLength', 0) <= len(value) <= schema.get('maxLength', 10000):
            raise ValueError(f"{path}: invalid length")
        if 'pattern' in schema and re.fullmatch(schema['pattern'], value) is None:
            raise ValueError(f"{path}: invalid format")


def _resolve_schema(schema, path, root_schema, references):
    reference = schema['$ref']
    if set(schema) != {'$ref'} or not reference.startswith('#/$defs/') or reference in references:
        raise ValueError(f'{path}: invalid or cyclic schema reference')
    definition = root_schema.get('$defs', {}).get(reference.removeprefix('#/$defs/'))
    if definition is None:
        raise ValueError(f'{path}: unresolved schema reference')
    return definition, (*references, reference)


def validate(value, schema, path="$", depth=0, root_schema=None, references=()):
    """Execute the closed JSON Schema subset used by the committed schemas."""
    root_schema = schema if root_schema is None else root_schema
    supported = {'$schema', '$defs', '$ref', 'type', 'properties', 'required', 'additionalProperties',
                 'items', 'minItems', 'maxItems', 'minimum', 'maximum', 'const',
                 'enum', 'pattern', 'minLength', 'maxLength'}
    if depth > 32 or set(schema) - supported:
        raise ValueError(f"{path}: unsupported schema/depth")
    if '$ref' in schema:
        definition, refs = _resolve_schema(schema, path, root_schema, references)
        return validate(value, definition, path, depth + 1, root_schema, refs)
    expected = schema.get('type')
    types = {'object': dict, 'array': list, 'string': str, 'integer': int}
    if expected and (type(value) is not types[expected]):
        raise ValueError(f"{path}: expected {expected}")
    if 'const' in schema and (type(value) is not type(schema['const']) or value != schema['const']):
        raise ValueError(f"{path}: incorrect constant")
    if 'enum' in schema and value not in schema['enum']:
        raise ValueError(f"{path}: unsupported value")
    if isinstance(value, dict):
        _validate_object(value, schema, path, depth, root_schema, references)
    elif isinstance(value, list):
        _validate_array(value, schema, path, depth, root_schema, references)
    else:
        _validate_scalar(value, schema, path)


def luminance(color):
    channels = [int(color[index:index + 2], 16) / 255 for index in (1, 3, 5)]
    linear = [part / 12.92 if part <= .04045 else ((part + .055) / 1.055) ** 2.4
              for part in channels]
    return sum(part * weight for part, weight in zip(linear, (.2126, .7152, .0722)))


def validate_semantics(tokens, catalog):
    for palette in ('colors', 'darkColors'):
        for foreground, background in tokens['contrastPairs']:
            levels = sorted([luminance(tokens[palette][foreground]), luminance(tokens[palette][background])])
            if (levels[1] + .05) / (levels[0] + .05) < 4.5:
                raise ValueError(f"Insufficient contrast: {palette}.{foreground}/{background}")
    for component in tokens['components'].values():
        pair = [component['foreground'], component['background']]
        if pair not in tokens['contrastPairs']:
            raise ValueError('Component contrast pair is not audited')
    for key, message in catalog['messages'].items():
        # This first catalog intentionally has no dynamic messages. Reject syntax
        # rather than accidentally shipping unresolved interpolation/plurals.
        if any(char in message['text'] for char in '{}%'):
            raise ValueError(f"Unsupported message interpolation: {key}")


def load_sources(root=ROOT):
    for directory, expected in (
        ('sources', {'tokens.jsonc', 'catalog.jsonc', 'app-icon.jsonc'}),
        ('schemas', {'tokens.schema.json', 'catalog.schema.json', 'app-icon.schema.json'}),
    ):
        entries = list((root / directory).iterdir())
        if {path.name for path in entries} != expected or any(path.is_symlink() or not path.is_file() for path in entries):
            raise ValueError(f'Unregistered or unsafe {directory} inventory')
    sources = []
    for name in ('tokens', 'catalog'):
        value = parse_jsonc((root / 'sources' / f'{name}.jsonc').read_text())
        schema = json.loads((root / 'schemas' / f'{name}.schema.json').read_text(), object_pairs_hook=unique_object)
        validate(value, schema)
        sources.append(value)
    validate_semantics(*sources)
    return tuple(sources)


def camel(key):
    parts = key.split('.')
    return parts[0] + ''.join(part[0].upper() + part[1:] for part in parts[1:])


def pseudo(text, rtl=False):
    expanded = ''.join({'a': 'á', 'e': 'ë', 'i': 'ï', 'o': 'ô', 'u': 'ü'}.get(char, char) for char in text)
    padded = expanded + ' ·' * max(3, (len(text) + 5) // 6)
    return ('\u2067[العربية ' + padded + ']\u2069') if rtl else '[' + padded + ']'


def quote(text):
    return json.dumps(text, ensure_ascii=False)


def source_identity(root):
    digest = hashlib.sha256(VERSION.encode())
    for path in sorted([*root.glob('sources/*.jsonc'), *root.glob('schemas/*.json')]):
        digest.update(str(path.relative_to(root)).encode())
        digest.update(path.read_bytes())
    digest.update((root / 'generate.py').read_bytes())
    return digest.hexdigest()



def ios_button_body(mapping, introduced_ios):
    binding = 'var' if {'foreground', 'background'} & mapping.keys() else 'let'
    if mapping['modern'] == mapping['fallback']:
        return [f'        {binding} configuration = UIButton.Configuration.{mapping["fallback"]}()']
    return [f'        {binding} configuration: UIButton.Configuration',
            f'        if #available(iOS {introduced_ios}.0, *) {{',
            f'            configuration = .{mapping["modern"]}()', '        } else {',
            f'            configuration = .{mapping["fallback"]}()', '        }']


def ios_primitive_source(tokens):
    """Resolve semantic roles through UIKit; never recreate OS colors or materials."""
    ios = tokens['platformPrimitives']['ios']
    lines = ['#if canImport(UIKit)', 'import UIKit', '',
             'public enum KenshikiIOSColorRole {']
    lines += [SWIFT_CASE + role for role in ios['colors']]
    lines += ['}', '', 'public enum KenshikiIOSTextRole {']
    lines += [SWIFT_CASE + role for role in ios['typography']]
    lines += ['}', '', '@MainActor public enum KenshikiIOSDesign {',
              '    public static func color(_ role: KenshikiIOSColorRole) -> UIColor {',
              '        switch role {']
    lines += [f'        case .{role}: return .{value}' for role, value in ios['colors'].items()]
    lines += ['        }', '    }',
              '    public static func font(_ role: KenshikiIOSTextRole) -> UIFont {',
              '        switch role {']
    lines += [f'        case .{role}: return .preferredFont(forTextStyle: .{value})'
              for role, value in ios['typography'].items()]
    lines += ['        }', '    }']
    for role, mapping in ios['buttons'].items():
        lines += [f'    public static func {role}Configuration() -> UIButton.Configuration {{']
        lines += ios_button_body(mapping, ios['material']['introducedIOS'])
        for property_name, token_name in (('baseForegroundColor', 'foreground'),
                                           ('baseBackgroundColor', 'background')):
            if token_name in mapping:
                lines.append(f'        configuration.{property_name} = color(.{mapping[token_name]})')
        lines += ['        return configuration', '    }']
    lines += ['}', '#endif', '', 'public enum KenshikiIOSPrimitives {']
    lines += [f'    public static let {role}Symbol = {quote(value)}'
              for role, value in ios['symbols'].items()]
    lines += ['}']
    return '\n'.join(lines) + '\n'


def material_primitive_source(tokens):
    """Reference adapters bind Compose roles; shared Kotlin stays platform-free."""
    android = tokens['platformPrimitives']['android']
    lines = ['', 'object KenshikiMaterialPrimitives {']
    for role, value in android['typography'].items():
        lines += [f'    val {role}: androidx.compose.ui.text.TextStyle',
                  f'        @androidx.compose.runtime.Composable get() = androidx.compose.material3.MaterialTheme.typography.{value}']
    for role, value in android['colors'].items():
        lines += [f'    val {role}: androidx.compose.ui.graphics.Color',
                  f'        @androidx.compose.runtime.Composable get() = androidx.compose.material3.MaterialTheme.colorScheme.{value}']
    lines += [f'    val {role}Icon: androidx.compose.ui.graphics.vector.ImageVector = {mapping["expression"]}'
              for role, mapping in android['symbols'].items()]
    lines += ['}', '', '@androidx.compose.runtime.Composable',
              'fun KenshikiMaterialTheme(content: @androidx.compose.runtime.Composable () -> Unit) {',
              '    val dark = androidx.compose.foundation.isSystemInDarkTheme()',
              '    val context = androidx.compose.ui.platform.LocalContext.current',
              '    val colors = when {',
              '        android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S && dark ->',
              '            androidx.compose.material3.dynamicDarkColorScheme(context)',
              '        android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S ->',
              '            androidx.compose.material3.dynamicLightColorScheme(context)',
              '        dark -> androidx.compose.material3.darkColorScheme()',
              '        else -> androidx.compose.material3.lightColorScheme()',
              '    }',
              '    androidx.compose.material3.MaterialTheme(colorScheme = colors, content = content)',
              '}']
    return '\n'.join(lines) + '\n'


def material_theme_resource(tokens, identity, night=False):
    theme = tokens['platformPrimitives']['android']['theme']
    parent = theme["nightParent"] if night else theme["parent"]
    return '\n'.join(['<?xml version="1.0" encoding="utf-8"?>',
                      f'<!-- Generated {identity}; DO NOT EDIT. -->', '<resources>',
                      f'    <style name="{theme["name"]}" parent="{parent}" />',
                      '</resources>', ''])


def swift_source(tokens, catalog, banner):
    lines = [banner, 'import Foundation', '', 'public enum KenshikiColor: String, CaseIterable {']
    lines += [SWIFT_CASE + name for name in tokens['colors']]
    lines += ['}', '', 'public enum KenshikiDesign {', '    public static func color(_ name: KenshikiColor, dark: Bool = false) -> UInt32 {', '        switch name {']
    lines += [f'        case .{name}: return dark ? 0x{tokens["darkColors"][name][1:]} : 0x{value[1:]}' for name, value in tokens['colors'].items()]
    lines += ['        }', '    }']
    values = {'pageSpacing':tokens['spacing']['page'], 'gapSpacing':tokens['spacing']['gap'], 'compactSpacing':tokens['spacing']['compact'], **tokens['dimensions'], **tokens['shape'], 'borderWidth':tokens['borders']['width'], 'cardElevation':tokens['elevation']['card'], **tokens['motion'], **{role + 'SizeSP': style['sizeSP'] for role, style in tokens['typography'].items()}}
    lines += [f'    public static let {name}: Double = {value}' for name, value in values.items()]
    lines += [f'    public static let {role}TextStyle = {quote(style["ios"])}' for role, style in tokens['typography'].items()]
    lines += ['}', '', 'public enum KenshikiCopy: String, CaseIterable {']
    lines += [f'    case {camel(key)} = {quote(key)}' for key in catalog['messages']]
    lines += ['    static var resourceBundle: Bundle {', '        #if SWIFT_PACKAGE', '        return .module', '        #else', '        return .main', '        #endif', '    }', '    public func localized(bundle: Bundle? = nil) -> String {', '        let selectedBundle = bundle ?? Self.resourceBundle', '        let value = selectedBundle.localizedString(forKey: rawValue, value: nil, table: "Localizable")', '        precondition(value != rawValue, "Missing localization resource")', '        return value', '    }', '    public static func text(_ key: String, bundle: Bundle? = nil) -> String {', '        guard let message = Self(rawValue: key) else { preconditionFailure("Unknown localization key") }', '        return message.localized(bundle: bundle)', '    }', '}']
    return '\n'.join(lines) + '\n\n' + ios_primitive_source(tokens)


def kotlin_source(tokens, catalog, banner):
    lines = [banner, 'package com.kenshiki.presentation.design', '', 'enum class KenshikiColor {']
    lines += ['    ' + name[0].upper() + name[1:] + (',' if index < len(tokens['colors']) - 1 else '') for index, name in enumerate(tokens['colors'])]
    lines += ['}', '', 'object KenshikiDesign {']
    for palette, values in (('lightColors', tokens['colors']), ('darkColors', tokens['darkColors'])):
        lines.append(f'    private val {palette} = mapOf(')
        lines += [f'        KenshikiColor.{name[0].upper()+name[1:]} to 0xFF{value[1:]}L,'
                  for name, value in values.items()]
        lines.append('    )')
    lines += ['    fun color(name: KenshikiColor, dark: Boolean = false): Long =',
              '        (if (dark) darkColors else lightColors).getValue(name)']
    values = {'pageSpacing':tokens['spacing']['page'], 'gapSpacing':tokens['spacing']['gap'], 'compactSpacing':tokens['spacing']['compact'], **tokens['dimensions'], **tokens['shape'], 'borderWidth':tokens['borders']['width'], 'cardElevation':tokens['elevation']['card'], **tokens['motion'], **{role + 'SizeSP': style['sizeSP'] for role, style in tokens['typography'].items()}}
    lines += [f'    const val {name}: Double = {value}.0' for name, value in values.items()]
    lines += [f'    const val {role}TextStyle = {quote(style["android"])}' for role, style in tokens['typography'].items()]
    lines += ['}', '', 'enum class KenshikiCopy(val key: String, val resourceName: String) {']
    keys = list(catalog['messages'])
    for index, key in enumerate(keys):
        identifier = camel(key)
        suffix = ';' if index == len(keys) - 1 else ','
        lines.append(f'    {identifier[0].upper()+identifier[1:]}({quote(key)}, {quote(android_name(key))}){suffix}')
    lines += ['    companion object {', '        fun fromKey(key: String): KenshikiCopy = entries.first { it.key == key }', '    }', '}']
    return '\n'.join(lines) + '\n'


def reference_resource_source(tokens, catalog, banner):
    lines = [banner, 'package com.kenshiki.reference.design', '',
             'import com.kenshiki.reference.R',
             'import com.kenshiki.presentation.design.KenshikiCopy']
    lines += ['import ' + mapping['import'] for mapping in tokens['platformPrimitives']['android']['symbols'].values()]
    lines += ['', '// Generated in the same catalog order as KenshikiCopy entries.',
              'private val copyResourceIds = intArrayOf(']
    lines += [f'    R.string.{android_name(key)},' for key in catalog['messages']]
    lines += [')', '', 'fun KenshikiCopy.resourceId(): Int = copyResourceIds[ordinal]']
    return '\n'.join(lines) + '\n' + material_primitive_source(tokens)


def android_name(key):
    return ''.join('_' + char.lower() if char.isupper() else '_' if char == '.' else char for char in key)


def app_icon_outputs(root):
    icon = parse_jsonc((root/'sources/app-icon.jsonc').read_text())
    validate(icon, json.loads((root/'schemas/app-icon.schema.json').read_text()))
    radii = icon['ringRadii']
    occupied = [icon['coreRadius'], *[radius + icon['strokeWidth'] / 2 for radius in radii]]
    if any(right - left <= icon['strokeWidth'] for left, right in zip(occupied, radii)):
        raise ValueError('App icon rings must remain ordered and separated')

    def fill(color):
        channels = [int(color[index:index + 2], 16) / 255 for index in (1, 3, 5)]
        return {'solid': 'srgb:' + ','.join(f'{value:.5f}' for value in channels) + ',1.00000'}

    def group(image, glass):
        return {'layers': [{'glass': glass, 'image-name': image + '.svg', 'name': image}],
                'shadow': {'kind': 'neutral', 'opacity': 0.5},
                'translucency': {'enabled': False, 'value': 0.5}}

    document = {'fill': fill(icon['background']),
                'fill-specializations': [{'value': fill(icon['background'])},
                                         {'appearance': 'dark', 'value': fill(icon['darkBackground'])}],
                'groups': [group('core', True), group('rings', False)],
                'supported-platforms': {'squares': 'shared'}}

    def gradient(colors, start, end):
        return (f'<defs><linearGradient id="g" gradientUnits="userSpaceOnUse" '
                f'x1="{start}" y1="{start}" x2="{end}" y2="{end}">'
                f'<stop offset="0" stop-color="{colors[0]}"/>'
                f'<stop offset="1" stop-color="{colors[1]}"/></linearGradient></defs>')

    svg = '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
    core = (svg + gradient(icon['coreGradient'], 440, 584) +
            f'<circle cx="512" cy="512" r="{icon["coreRadius"]}" fill="url(#g)"/></svg>\n')
    rings = svg + gradient(icon['ringsGradient'], 200, 824)
    rings += f'<g fill="none" stroke="url(#g)" stroke-linecap="round" stroke-width="{icon["strokeWidth"]}">'
    for radius, opacity in zip(radii, icon['ringOpacityPercent']):
        rings += (f'<path d="M 512 {512 - radius} A {radius} {radius} 0 1 1 {512 - radius} 512" '
                  f'stroke-opacity="{opacity / 100:g}"/>')
    rings += '</g></svg>\n'
    prefix = 'ios/' + icon['name'] + '.icon/'
    return {prefix + 'icon.json': json.dumps(document, indent=2) + '\n',
            prefix + 'Assets/core.svg': core, prefix + 'Assets/rings.svg': rings}


def outputs(root=ROOT):
    tokens, catalog = load_sources(root)
    identity = source_identity(root)
    banner = f'// Generated by {VERSION}; source/schema/generator sha256 {identity}. DO NOT EDIT.'
    result = {'swift/KenshikiDesign.swift': swift_source(tokens, catalog, banner), 'android/kotlin/KenshikiDesign.kt': kotlin_source(tokens, catalog, banner), 'android/reference/KenshikiCopyResources.kt': reference_resource_source(tokens, catalog, banner)}
    result['android/res/values/themes.xml'] = material_theme_resource(tokens, identity)
    result['android/res/values-night/themes.xml'] = material_theme_resource(tokens, identity, night=True)
    locales = [('en', 'en', None), ('en-XA', 'en-rXA', False), ('ar-XB', 'ar-rXB', True)]
    for locale, android_locale, rtl in locales:
        messages = {key: value['text'] if rtl is None else pseudo(value['text'], rtl) for key, value in catalog['messages'].items()}
        native = [banner] + [f'{quote(key)} = {quote(value)};' for key, value in messages.items()]
        result[f'swift/{locale}.lproj/Localizable.strings'] = '\n'.join(native) + '\n'
        permissions = {'CFBundleDisplayName': messages['app.title'], 'NSCameraUsageDescription': messages['permission.camera'], 'NSMotionUsageDescription': messages['permission.motion'], 'NSLocationWhenInUseUsageDescription': messages['permission.location'], 'NFCReaderUsageDescription': messages['permission.nfc']}
        result[f'swift/{locale}.lproj/InfoPlist.strings'] = '\n'.join([banner] + [f'{quote(key)} = {quote(value)};' for key, value in permissions.items()]) + '\n'
        xml = ['<?xml version="1.0" encoding="utf-8"?>', f'<!-- Generated {identity}; DO NOT EDIT. -->', '<resources>']
        for key, value in messages.items():
            escaped = escape(value).replace("'", "\\'").replace('"', '\\"')
            xml.append(f'    <string name="{android_name(key)}">{escaped}</string>')
        result[f'android/res/{"values" if locale == "en" else "values-" + android_locale}/strings.xml'] = '\n'.join(xml + ['</resources>']) + '\n'
    result.update(app_icon_outputs(root))
    return result


def generate(check=False, root=ROOT):
    expected = outputs(root)
    destination = root / 'generated'
    actual_paths = {str(path.relative_to(destination)) for path in destination.rglob('*') if path.is_file()}
    if check:
        if actual_paths != set(expected):
            raise ValueError('Generated file inventory drift')
        for name, contents in expected.items():
            if (destination / name).read_bytes() != contents.encode():
                raise ValueError(f'Generated resource drift: {name}')
    else:
        if actual_paths - expected.keys():
            raise ValueError('Unmanaged generated files; inspect before regenerating')
        for name, contents in expected.items():
            path = destination / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(contents.encode())
    return expected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Read-only byte/inventory drift check')
    arguments = parser.parse_args()
    try:
        result = generate(arguments.check)
    except (ValueError, OSError) as error:
        parser.exit(1, f'{error}\n')
    print(f'Design sources validated; {len(result)} generated artifacts {"verified" if arguments.check else "written"}.')


if __name__ == '__main__':
    main()
