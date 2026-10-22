#!/usr/bin/env python3
"""
validate.py - static checks on everything under automation/.

This is not a substitute for `terraform validate` / `az bicep build` /
`cfn-lint`, which need the real toolchain. It is the check that can run
anywhere, and it catches the errors that actually bite when copying templates
between clouds: a var.* that was never declared, a resource reference with a
typo, unparseable HCL, malformed JSON/YAML, and - the one that matters most
here - a credential accidentally committed.

    python automation/validate.py
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

FAIL = []
WARN = []
OK = []


def fail(what, msg):
    FAIL.append(f'{what}: {msg}')


def ok(what, msg=''):
    OK.append(f'{what}{": " + msg if msg else ""}')


def walk(ext):
    for root, _, files in os.walk(HERE):
        for f in sorted(files):
            if f.endswith(ext):
                yield os.path.join(root, f)


def rel(p):
    return os.path.relpath(p, HERE).replace('\\', '/')


# ------------------------------------------------------------------ terraform

def check_terraform():
    try:
        import hcl2
    except ImportError:
        WARN.append('terraform: python-hcl2 not installed, skipping HCL parse')
        return

    for path in walk('.tf'):
        name = rel(path)
        raw = open(path, encoding='utf-8').read()
        # Strip comments before scanning for references. Comments legitimately
        # name resources and attributes while explaining them ("field X was
        # added in provider 4.11"), and counting those as references makes the
        # checker report a resource that was only ever mentioned in prose.
        text = re.sub(r'(?m)(^|\s)(#|//)[^\n]*', r'\1', raw)
        text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
        try:
            with open(path, encoding='utf-8') as fh:
                doc = hcl2.load(fh)
        except Exception as e:
            fail(name, f'HCL parse error: {type(e).__name__}: {e}')
            continue

        # hcl2 hands back block labels still wrapped in their quote characters
        # on some versions, so normalise before comparing against var.X names.
        def unquote(s):
            return s.strip().strip('"').strip("'")

        declared_vars = set()
        for block in doc.get('variable', []):
            declared_vars.update(unquote(k) for k in block.keys())

        # Every var.X referenced must be declared in the same file. These
        # configs are single-file by design, so a cross-file reference is a
        # copy/paste leftover rather than a legitimate split.
        used = set(re.findall(r'\bvar\.([a-z_][a-z0-9_]*)', text))
        missing = sorted(used - declared_vars)
        if missing:
            fail(name, f'references undeclared variables: {missing}')

        unused = sorted(declared_vars - used)
        if unused:
            WARN.append(f'{name}: declared but unused variables: {unused}')

        # Resource/data addresses that are referenced but never defined.
        defined = set()
        for block in doc.get('resource', []):
            for rtype, bodies in block.items():
                for rname in bodies:
                    defined.add(f'{unquote(rtype)}.{unquote(rname)}')
        for block in doc.get('data', []):
            for dtype, bodies in block.items():
                for dname in bodies:
                    defined.add(f'data.{unquote(dtype)}.{unquote(dname)}')

        refs = set()
        for m in re.finditer(r'(?<![\w.])(data\.[a-z][a-z0-9_]*\.[a-z_][a-z0-9_]*'
                             r'|[a-z][a-z0-9_]*_[a-z0-9_]*\.[a-z_][a-z0-9_]*)'
                             r'(?=[\s.\[\],)}])', text):
            r = m.group(1)
            # Skip provider-ish and meta references.
            if r.split('.')[0] in ('var', 'local', 'each', 'count', 'self',
                                   'terraform', 'path', 'module'):
                continue
            refs.add(r)

        unknown = sorted(r for r in refs
                         if r not in defined
                         and not r.startswith('aws_iam_policy_document.')
                         and r.count('.') == 1
                         and not r.startswith('data.'))
        # Only report ones that look like in-file resource refs.
        unknown = [u for u in unknown if u.split('.')[0].count('_') >= 1
                   and any(u.split('.')[0] == d.split('.')[0] for d in defined)]
        if unknown:
            fail(name, f'references undefined resources: {unknown}')

        if 'required_version' not in text:
            WARN.append(f'{name}: no terraform.required_version pin')

        if not missing and not unknown:
            ok(name, f'{len(defined)} resources, {len(declared_vars)} variables')


# ----------------------------------------------------------------- json/yaml

def check_json():
    for path in walk('.json'):
        name = rel(path)
        try:
            json.load(open(path, encoding='utf-8'))
            ok(name, 'valid JSON')
        except Exception as e:
            fail(name, f'invalid JSON: {e}')


def check_yaml():
    try:
        import yaml
    except ImportError:
        WARN.append('yaml: PyYAML not installed, skipping YAML parse')
        return

    # CloudFormation short forms (!Ref, !GetAtt, ...) are not standard YAML
    # tags; register a passthrough so the structure can still be validated.
    class CFN(yaml.SafeLoader):
        pass

    def _multi(loader, suffix, node):
        if isinstance(node, yaml.ScalarNode):
            return loader.construct_scalar(node)
        if isinstance(node, yaml.SequenceNode):
            return loader.construct_sequence(node)
        return loader.construct_mapping(node)

    CFN.add_multi_constructor('!', _multi)

    for path in list(walk('.yaml')) + list(walk('.yml')):
        name = rel(path)
        try:
            doc = yaml.load(open(path, encoding='utf-8'), Loader=CFN)
            if doc is None:
                fail(name, 'empty YAML document')
                continue
            ok(name, f'valid YAML, {len(doc)} top-level keys'
               if isinstance(doc, dict) else 'valid YAML')
        except Exception as e:
            fail(name, f'invalid YAML: {e}')


# --------------------------------------------------------------- credentials
# The one check that must never be skipped.

def check_no_secrets():
    # A JWT is three base64url segments; the header of an RS256/HS256 token
    # always begins 'eyJ'. Flag any long literal that looks like one.
    jwt = re.compile(r'eyJ[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{8,}')
    generic = re.compile(r'(?i)\b(secret_string|password|api[_-]?key)\s*[:=]\s*'
                         r'["\'][A-Za-z0-9+/_=-]{16,}["\']')
    hits = []
    for root, dirs, files in os.walk(HERE):
        dirs[:] = [d for d in dirs if d not in ('.terraform', '__pycache__', 'build', 'runs')]
        for f in files:
            if f.endswith(('.zip', '.pyc')):
                continue
            p = os.path.join(root, f)
            try:
                text = open(p, encoding='utf-8', errors='ignore').read()
            except OSError:
                continue
            for rx, label in ((jwt, 'JWT-shaped literal'), (generic, 'inline secret')):
                for m in rx.finditer(text):
                    hits.append(f'{rel(p)}: {label} at offset {m.start()}')
    if hits:
        for h in hits:
            fail('SECRET SCAN', h)
    else:
        ok('SECRET SCAN', 'no credential-shaped literals in automation/')


# ---------------------------------------------------------------------- main

def main():
    check_terraform()
    check_json()
    check_yaml()
    check_no_secrets()

    for line in OK:
        print(f'  PASS  {line}')
    for line in WARN:
        print(f'  WARN  {line}')
    for line in FAIL:
        print(f'  FAIL  {line}')

    print(f'\n{len(OK)} passed, {len(WARN)} warnings, {len(FAIL)} failures')
    return 1 if FAIL else 0


if __name__ == '__main__':
    sys.exit(main())
