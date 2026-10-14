#!/usr/bin/env python3
# Regenerates Sources/KinhinKit/Mobile/MobileTemplates.swift from templates/mobile/.
# MobileScaffoldTests fails when the two drift, so run this after any template change.
import os
import subprocess
root = 'templates/mobile'
files = sorted(os.path.relpath(os.path.join(dp, f), root) for dp, _, fn in os.walk(root) for f in fn)
def ident(rel):
    parts = rel.replace('.', '_').replace('-', '_').replace('/', '_').split('_')
    return parts[0] + ''.join(p[:1].upper() + p[1:] for p in parts[1:])
out = [
    '// Generated from templates/mobile/ by scripts/mobile-templates-embed.py. Do not edit by hand:',
    '// MobileScaffoldTests fails when this file and the template files differ.',
    '',
    'enum MobileTemplates {',
    '    /// Template text by its path under templates/mobile/.',
    '    static let files: [String: String] = [',
]
out += [f'        "{rel}": {ident(rel)},' for rel in files]
out += ['    ]', '']
for rel in files:
    text = open(os.path.join(root, rel)).read()
    if text.endswith('\n'):
        text = text[:-1]
    assert '"""#' not in text, rel
    out += [f'    private static let {ident(rel)} = #"""', text, '"""#', '']
out += ['}']
target = 'Sources/KinhinKit/Mobile/MobileTemplates.swift'
open(target, 'w').write('\n'.join(out) + '\n')
# The repo lints with swift-format --strict, so the generated file is formatted the same way.
subprocess.run(['swift', 'format', 'format', '-i', target], check=True)
print(len(files), 'templates embedded')
