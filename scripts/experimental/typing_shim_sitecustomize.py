"""Compat shim: Frida 17 imports typing.NotRequired/ParamSpec (3.10/3.11+).
Stock macOS /usr/bin/python3 is often 3.9 — map names from typing_extensions.
Installed into venv as sitecustomize.py when base Python < 3.11.
"""
try:
    import typing

    try:
        import typing_extensions as te
    except ImportError:
        te = None
    if te is not None:
        for _name in (
            "NotRequired",
            "Required",
            "Self",
            "TypeAlias",
            "ParamSpec",
            "Concatenate",
            "TypeVarTuple",
            "Unpack",
            "LiteralString",
            "TypeGuard",
            "TypeIs",
            "ReadOnly",
        ):
            if not hasattr(typing, _name) and hasattr(te, _name):
                try:
                    setattr(typing, _name, getattr(te, _name))
                except Exception:
                    pass
except Exception:
    pass
