const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = fs.readFileSync('src/services/browser_canvas_guard.js', 'utf8');
function make(host, exceptions) {
    class Canvas { toDataURL() { return 'pixels'; } toBlob() { return 'blob'; } captureStream() {} }
    class Context { getImageData() { return [1]; } fillRect() { return 'drawn'; } }
    class GL { readPixels() { return 'gpu'; } }
    class Offscreen { convertToBlob() {} transferToImageBitmap() {} }
    const context = { location: {hostname:host}, DOMException, HTMLCanvasElement: Canvas, CanvasRenderingContext2D: Context, WebGLRenderingContext: GL, OffscreenCanvas: Offscreen };
    vm.runInNewContext(source.replace('__OPAL_EXCEPTIONS__', JSON.stringify(exceptions)), context);
    return {Canvas, Context, GL, Offscreen};
}
let p = make('tracking.example', []);
assert.throws(() => new p.Canvas().toDataURL(), {name:'SecurityError'});
assert.throws(() => new p.Context().getImageData(), {name:'SecurityError'});
assert.throws(() => new p.GL().readPixels(), {name:'SecurityError'});
assert.throws(() => new p.Offscreen().convertToBlob(), {name:'SecurityError'});
assert.equal(new p.Context().fillRect(), 'drawn');
p = make('EDITOR.EXAMPLE', ['editor.example']);
assert.equal(new p.Canvas().toDataURL(), 'pixels');
p = make('evil.editor.example', ['editor.example']);
assert.throws(() => new p.Canvas().toDataURL(), {name:'SecurityError'});
console.log('Canvas guard: readback blocked, drawing preserved, exact-host exceptions verified');
