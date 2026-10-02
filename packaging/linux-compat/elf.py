"""Inspect the x86-64 ELF files shipped by the compatibility package."""
import struct
from pathlib import Path
import subprocess


def has_dynamic_segment(binary):
    with open(binary, 'rb') as source:
        header = source.read(64)
        if len(header) != 64 or header[:6] != b'\x7fELF\x02\x01':
            raise ValueError('expected a complete little-endian ELF64 header')
        offset = struct.unpack_from('<Q', header, 32)[0]
        size, count = struct.unpack_from('<HH', header, 54)
        if size < 56 or count == 0xffff:
            raise ValueError('unsupported ELF program header table')
        dynamic = False
        for index in range(count):
            source.seek(offset + index * size)
            segment = source.read(size)
            if len(segment) != size:
                raise ValueError('truncated ELF program header table')
            dynamic |= struct.unpack_from('<I', segment)[0] == 2  # PT_DYNAMIC
        return dynamic


def relocate_private_libraries(binary, directory, prefix='/opt/opal-runtime', patchelf='patchelf'):
    needed = subprocess.check_output([patchelf, '--print-needed', str(binary)], text=True).splitlines()
    for dependency in needed:
        if dependency.startswith(prefix + '/'):
            name = Path(dependency).name
            if not (Path(directory) / name).is_file():
                raise ValueError('private dependency missing from package: ' + dependency)
            subprocess.run([patchelf, '--replace-needed', dependency, name, str(binary)], check=True)
    subprocess.run([patchelf, '--set-rpath', '$ORIGIN', str(binary)], check=True)
