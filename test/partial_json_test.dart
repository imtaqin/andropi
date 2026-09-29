import 'package:andropi/agent/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reads a value that is still being streamed', () {
    final args = partialJsonStrings(r'{"path": "index.html", "content": "<h1>Hi</h1>\n<p>wor');
    expect(args['path'], 'index.html');
    expect(args['content'], '<h1>Hi</h1>\n<p>wor');
  });

  test('decodes escapes and stops before a cut escape', () {
    expect(partialJsonStrings(r'{"a": "say \"hi\"\tA"}')['a'], 'say "hi"\tA');
    expect(partialJsonStrings(r'{"a": "x\')['a'], 'x');
    expect(partialJsonStrings(r'{"a": "x\u00')['a'], 'x');
  });

  test('keeps the latest repeated key', () {
    final args = partialJsonStrings(r'{"path":"a.html","edits":[{"oldText":"1","newText":"2"},{"oldText":"3","newText":"4');
    expect(args['newText'], '4');
  });

  test('empty or keyless input', () {
    expect(partialJsonStrings(''), isEmpty);
    expect(partialJsonStrings('{"pa'), isEmpty);
  });
}
