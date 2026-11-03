// Drawing remains available. Fingerprinting readback requires a site exception.
((exceptions) => {
    'use strict';
    if (exceptions.some(host => host.toLowerCase() === location.hostname.toLowerCase())) return;
    const deny = () => { throw new DOMException('Canvas readback is blocked by Opal. Allow canvas for this site in browser protections.', 'SecurityError'); };
    const protect = (prototype, methods) => {
        if (!prototype) return;
        for (const name of methods) {
            if (typeof prototype[name] !== 'function') continue;
            Object.defineProperty(prototype, name, { value: deny, writable: false, configurable: false });
        }
    };
    protect(globalThis.HTMLCanvasElement?.prototype, ['toDataURL', 'toBlob', 'captureStream']);
    protect(globalThis.CanvasRenderingContext2D?.prototype, ['getImageData']);
    protect(globalThis.OffscreenCanvas?.prototype, ['convertToBlob', 'transferToImageBitmap']);
    protect(globalThis.OffscreenCanvasRenderingContext2D?.prototype, ['getImageData']);
    protect(globalThis.WebGLRenderingContext?.prototype, ['readPixels']);
    protect(globalThis.WebGL2RenderingContext?.prototype, ['readPixels', 'getBufferSubData']);
})(__OPAL_EXCEPTIONS__);
