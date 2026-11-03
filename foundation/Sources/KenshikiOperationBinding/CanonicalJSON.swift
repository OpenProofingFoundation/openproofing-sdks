import Foundation
import JavaScriptCore

/// RFC 8785 serialization for new sealed-operation content and results on Apple platforms.
/// Uses the system ECMAScript engine for IEEE-754 formatting rather than decimal rounding.
/// No caller data is evaluated as executable source; each call owns an isolated context.
public enum CanonicalJSON {
    public enum Failure: Error { case invalidJSON, unavailableRuntime }

    public static func data(withJSONObject object: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else { throw Failure.invalidJSON }
        return try canonicalize(JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]))
    }

    public static func canonicalize(_ data: Data) throws -> Data {
        guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8) else { throw Failure.invalidJSON }
        guard let context = JSContext(), let function = context.evaluateScript(source), !function.isUndefined else {
            throw Failure.unavailableRuntime
        }
        let output = function.call(withArguments: [text])
        guard context.exception == nil, let output, output.isString, let canonical = output.toString() else {
            throw Failure.invalidJSON
        }
        return Data(canonical.utf8)
    }

    // RFC 8785 sections 3.2.2/3.2.3: ECMAScript primitives, UTF-16 key order, no Unicode normalization.
    // JSON.parse validates grammar; the second bounded traversal rejects duplicate keys before they disappear.
    private static let source = #"""
    (function(text) {
      'use strict';
      const value = JSON.parse(text);
      let index = 0;
      function whitespace() { while (/\s/.test(text[index] || '') && index < text.length) index++; }
      function stringToken() {
        const begin = index++;
        while (index < text.length) {
          if (text[index] === '\\') { index += 2; continue; }
          if (text[index++] === '"') return JSON.parse(text.slice(begin,index));
        }
        throw Error('string');
      }
      function scan(depth) {
        if (depth > 128) throw Error('depth');
        whitespace();
        if (text[index] === '{') {
          index++; whitespace(); const names = new Set();
          if (text[index] === '}') { index++; return; }
          while (true) {
            whitespace(); const key = stringToken();
            if (names.has(key)) throw Error('duplicate');
            names.add(key); whitespace(); index++; scan(depth+1); whitespace();
            if (text[index++] === '}') return;
          }
        }
        if (text[index] === '[') {
          index++; whitespace();
          if (text[index] === ']') { index++; return; }
          while (true) { scan(depth+1); whitespace(); if (text[index++] === ']') return; }
        }
        if (text[index] === '"') { stringToken(); return; }
        while (index < text.length && !/[\s,}\]]/.test(text[index])) index++;
      }
      scan(0);
      function quoted(value) {
        for (let i=0;i<value.length;i++) {
          const unit=value.charCodeAt(i);
          if (unit>=0xd800 && unit<=0xdbff) {
            const next=value.charCodeAt(++i);
            if (!(next>=0xdc00 && next<=0xdfff)) throw Error('surrogate');
          } else if (unit>=0xdc00 && unit<=0xdfff) throw Error('surrogate');
        }
        return JSON.stringify(value);
      }
      function emit(value) {
        if (typeof value === 'string') return quoted(value);
        if (typeof value === 'number' && !Number.isFinite(value)) throw Error('number');
        if (value === null || typeof value !== 'object') return JSON.stringify(value);
        if (Array.isArray(value)) return '['+value.map(emit).join(',')+']';
        return '{'+Object.keys(value).sort().map(key=>quoted(key)+':'+emit(value[key])).join(',')+'}';
      }
      return emit(value);
    })
    """#
}
