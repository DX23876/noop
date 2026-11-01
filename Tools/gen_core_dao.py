#!/usr/bin/env python3
"""Generates Android's DAO implementation over the shared core (fork, Android without Room).

`android/app/src/main/java/com/noop/data/WhoopDao.kt` and `DeviceRegistryDao.kt` keep declaring the data access as
they did for Room: annotated interface methods (`@Query`, `@Insert`, `@Upsert`, `@Update`). Room no longer
generates their implementation; this script does, as `CoreWhoopDao.kt`, and every statement runs in the core's
store through `CoreDb` (the tables and columns are the same, `schema_oracle.json`). Entities and projections are
mapped by column name, as Room maps them.

    python3 Tools/gen_core_dao.py          # rewrite CoreWhoopDao.kt
    python3 Tools/gen_core_dao.py --check  # fail when it is out of date (Tools tests)
"""
from __future__ import annotations

import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "android/app/src/main/java/com/noop/data"
DAO_FILES = [DATA / "WhoopDao.kt", DATA / "DeviceRegistryDao.kt"]
CLASS_FILES = [DATA / "Entities.kt", DATA / "PairedDevice.kt", DATA / "WhoopDao.kt"]
OUT = DATA / "CoreWhoopDao.kt"

PRIMITIVES = {"Int", "Long", "Double", "Float", "String", "Boolean", "ByteArray"}


def matching(text: str, start: int, open_ch: str = "(", close_ch: str = ")") -> int:
    """Index just past the bracket closing the one at `start`, skipping string literals."""
    depth, i = 0, start
    while i < len(text):
        if text.startswith('"""', i):
            i = text.index('"""', i + 3) + 3
            continue
        c = text[i]
        if c == '"':
            i += 1
            while text[i] != '"':
                i += 2 if text[i] == "\\" else 1
            i += 1
            continue
        if c == open_ch:
            depth += 1
        elif c == close_ch:
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    raise ValueError("unbalanced")


def split_top(text: str, sep: str = ",") -> list[str]:
    """Split on `sep` outside brackets, generics and strings."""
    parts, depth, cur, i = [], 0, [], 0
    while i < len(text):
        c = text[i]
        if c == '"':
            j = i + 1
            while text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            cur.append(text[i:j + 1]); i = j + 1; continue
        if c in "(<[{":
            depth += 1
        elif c in ")>]}":
            depth -= 1
        if c == sep and depth == 0:
            parts.append("".join(cur)); cur = []
        else:
            cur.append(c)
        i += 1
    if "".join(cur).strip():
        parts.append("".join(cur))
    return parts


def strip_comments(text: str) -> str:
    """Kotlin comments blanked (same length), so positions stay valid and annotations inside KDoc are ignored."""
    out, i = list(text), 0
    while i < len(text):
        if text.startswith('"""', i):
            i = text.index('"""', i + 3) + 3; continue
        if text[i] == '"':
            j = i + 1
            while text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            i = j + 1; continue
        if text.startswith("/*", i):
            j = text.index("*/", i) + 2
            for k in range(i, j):
                if out[k] != "\n": out[k] = " "
            i = j; continue
        if text.startswith("//", i):
            j = text.find("\n", i); j = len(text) if j < 0 else j
            for k in range(i, j): out[k] = " "
            i = j; continue
        i += 1
    return "".join(out)


@dataclass
class Param:
    name: str
    type: str
    column: str
    default: str | None = None


@dataclass
class KClass:
    name: str
    params: list[Param]
    table: str | None = None
    primary_keys: list[str] = field(default_factory=list)
    qualified: str = ""


def parse_classes() -> dict[str, KClass]:
    classes: dict[str, KClass] = {}
    for path in CLASS_FILES:
        raw = path.read_text(encoding="utf-8")
        text = strip_comments(raw)
        prev_end = 0
        # Classes declared inside an interface body are referred to through it (`WhoopDao.StreamPresence`).
        scopes = []
        for im in re.finditer(r"\binterface (\w+)[^{]*\{", text):
            scopes.append((im.end() - 1, matching(text, im.end() - 1, "{", "}"), im.group(1)))
        for m in re.finditer(r"\bdata class (\w+)\s*\(", text):
            name = m.group(1)
            end = matching(text, m.end() - 1)
            body = text[m.end():end - 1]
            params, pk_fields = [], []
            for part in split_top(body):
                part = part.strip()
                if not part:
                    continue
                column = None
                cm = re.search(r'@ColumnInfo\([^)]*name\s*=\s*"(\w+)"', part)
                if cm:
                    column = cm.group(1)
                pk_here = "PrimaryKey" in part
                part = re.sub(r"@[\w.]+(\([^)]*\))?", "", part).strip()
                pm = re.match(r"(?:val|var)\s+(\w+)\s*:\s*(.+)$", part, re.S)
                if not pm:
                    continue
                pname, rest = pm.group(1), pm.group(2).strip()
                eq = split_top(rest, "=")
                default = "=".join(eq[1:]).strip() if len(eq) > 1 else None
                params.append(Param(pname, eq[0].strip(), column or pname, default))
                if pk_here:
                    pk_fields.append(column or pname)
            # Only an @Entity between the previous class and this one belongs to this one.
            head = text[prev_end:m.start()]
            prev_end = end
            em = None
            for em in re.finditer(r"@Entity\s*\(", head):
                pass
            table, pks = None, []
            if em:
                ann = head[em.start():]
                tm = re.search(r'tableName\s*=\s*"(\w+)"', ann)
                table = tm.group(1) if tm else None
                km = re.search(r"primaryKeys\s*=\s*\[([^\]]*)\]", ann)
                if km:
                    pks = re.findall(r'"(\w+)"', km.group(1))
            if not pks:
                pks = pk_fields
            outer = next((n for a, b, n in scopes if a < m.start() < b), None)
            if name not in classes or table:
                classes[name] = KClass(name, params, table, pks, f"{outer}.{name}" if outer else name)
    return classes


@dataclass
class Method:
    name: str
    params: list[tuple[str, str]]
    ret: str
    suspend: bool
    kind: str          # query | insert | upsert | update | delete
    sql: str | None = None
    conflict: str | None = None


def parse_methods() -> list[Method]:
    methods: list[Method] = []
    for path in DAO_FILES:
        raw = path.read_text(encoding="utf-8")
        text = strip_comments(raw)
        start = text.index("interface ")
        body_start = text.index("{", start)
        i = body_start + 1
        prev_end = i
        for m in re.finditer(r"(?:(suspend)\s+)?fun\s+(\w+)\s*\(", text[body_start:]):
            fstart = body_start + m.start()
            if fstart < prev_end:
                continue
            pstart = body_start + m.end() - 1
            pend = matching(text, pstart)
            after = text[pend:]
            rm = re.match(r"\s*(?::\s*([^\n{=]+?))?\s*(\{|=|\n)", after)
            ret = (rm.group(1) or "Unit").strip() if rm else "Unit"
            has_body = bool(rm and rm.group(2) in "{=")
            if rm and rm.group(2) == "\n":
                nxt = after[rm.end():].lstrip()
                has_body = nxt.startswith("{") or nxt.startswith("=")
            if has_body:
                # skip the body
                bpos = text.index(after[rm.end() - 1:].lstrip()[0], pend + rm.start(2) if rm else pend)
                if text[bpos] == "{":
                    prev_end = matching(text, bpos, "{", "}")
                else:
                    prev_end = text.find("\n\n", bpos)
                continue
            region_start = prev_end
            region = text[region_start:fstart]
            prev_end = pend
            ann = None
            for am in re.finditer(r"@(Query|Insert|Upsert|Update|Delete)\b", region):
                ann = am
            if not ann:
                continue
            kind = ann.group(1).lower()
            sql = conflict = None
            rest = region[ann.end():]
            if rest.lstrip().startswith("("):
                astart = ann.end() + region[ann.end():].index("(")
                aend = matching(region, astart)
                arg = region[astart + 1:aend - 1].strip()
                if kind == "query":
                    # The argument from the raw text at the same offsets (comments were blanked).
                    sql = raw[region_start + astart + 1:region_start + aend - 1].strip().rstrip(",").rstrip()
                else:
                    cm2 = re.search(r"OnConflictStrategy\.(\w+)", arg)
                    conflict = cm2.group(1) if cm2 else None
            params = []
            for part in split_top(text[pstart + 1:pend - 1]):
                part = re.sub(r"@[\w.]+(\([^)]*\))?", "", part).strip()
                if not part:
                    continue
                pm = re.match(r"(\w+)\s*:\s*([^=]+?)\s*(=.*)?$", part, re.S)
                params.append((pm.group(1), " ".join(pm.group(2).split())))
            methods.append(Method(m.group(2), params, " ".join(ret.split()), bool(m.group(1)), kind, sql, conflict))
    return methods


def getter(ptype: str, column: str) -> str:
    nullable = ptype.endswith("?")
    base = ptype.rstrip("?")
    fn = {"Int": "int", "Long": "long", "Double": "double", "Float": "float", "String": "string",
          "Boolean": "bool", "ByteArray": "blob"}.get(base)
    if fn is None:
        raise ValueError(f"no getter for {ptype}")
    return f'r.{fn}{"OrNull" if nullable else ""}("{column}")'


def mapper(cls: KClass) -> str:
    lines = [f"internal fun row{cls.name}(r: CoreDb.Row): {cls.qualified} = {cls.qualified}("]
    for p in cls.params:
        value = getter(p.type, p.column)
        if p.default is not None:
            value = f'if (r.has("{p.column}")) {value} else {p.default}'
        lines.append(f"    {p.name} = {value},")
    lines.append(")")
    return "\n".join(lines)


def scalar(base: str, expr: str) -> str:
    return {
        "Int": f"CoreDb.scalarLong({expr})?.toInt()",
        "Long": f"CoreDb.scalarLong({expr})",
        "Double": f"CoreDb.scalarDouble({expr})",
        "Float": f"CoreDb.scalarDouble({expr})?.toFloat()",
        "String": f"CoreDb.scalarString({expr})",
        "Boolean": f"CoreDb.scalarLong({expr})?.let {{ it != 0L }}",
    }[base]


def column_value(base: str) -> str:
    return {"Int": "(it.first()?.let(CoreDb::number)?.toInt() ?: 0)",
            "Long": "(it.first()?.let(CoreDb::number)?.toLong() ?: 0L)",
            "Double": "(it.first()?.let(CoreDb::number)?.toDouble() ?: 0.0)",
            "String": "(it.first()?.toString() ?: \"\")"}[base]


def query_body(m: Method, classes: dict[str, KClass], used: set[str]) -> str:
    args = ", ".join(f'"{n}" to {n}' for n, _ in m.params)
    params = f"mapOf({args})" if args else "emptyMap()"
    ret = m.ret
    flow = ret.startswith("Flow<")
    inner = ret[5:-1] if flow else ret
    q = f"CoreDb.query(SQL_{m.name}, {params})"
    nullable = inner.endswith("?")
    base = inner.rstrip("?")
    if base == "Unit":
        body = f"CoreDb.exec(SQL_{m.name}, {params})"
    elif base.startswith("List<"):
        el = base[5:-1]
        if el in PRIMITIVES:
            body = f"{q}.map {{ {column_value(el)} }}"
        else:
            el = el.split(".")[-1]
            used.add(el)
            body = f"{q}.map(::row{el})"
    elif base in ("Int", "Long") and not flow:
        read = scalar(base, q)
        body = (f"if (CoreDb.isRead(SQL_{m.name})) ({read}{'' if nullable else ' ?: 0'}) "
                f"else CoreDb.exec(SQL_{m.name}, {params}){'.toLong()' if base == 'Long' else ''}")
    elif base in PRIMITIVES:
        zero = {"Int": "0", "Long": "0L", "Double": "0.0", "Float": "0f", "String": '""', "Boolean": "false"}[base]
        body = f"{scalar(base, q)}" + ("" if nullable else f" ?: {zero}")
    else:
        base = base.split(".")[-1]
        used.add(base)
        body = f"{q}.firstOrNull()?.let(::row{base})" + ("" if nullable else f' ?: error("{m.name}: no row")')
    if flow:
        return f"CoreDb.observe {{ {body} }}"
    return body


def write_body(m: Method, classes: dict[str, KClass], used: set[str]) -> str:
    (pname, ptype), = m.params
    many = ptype.startswith("List<") or ptype.startswith("Collection<")
    el = ptype[ptype.index("<") + 1:-1] if many else ptype
    cls = classes[el]
    cols = [p.column for p in cls.params]
    vals = ", ".join(f"row.{p.name}" for p in cls.params)
    col_list = ", ".join(f"`{c}`" for c in cols)
    marks = ", ".join("?" for _ in cols)
    if m.kind == "insert":
        verb = {"REPLACE": "INSERT OR REPLACE", "IGNORE": "INSERT OR IGNORE", "ABORT": "INSERT",
                None: "INSERT"}[m.conflict]
        sql = f"{verb} INTO `{cls.table}` ({col_list}) VALUES ({marks})"
    elif m.kind == "upsert":
        sets = ", ".join(f"`{c}` = excluded.`{c}`" for c in cols if c not in cls.primary_keys)
        keys = ", ".join(f"`{k}`" for k in cls.primary_keys)
        sql = f"INSERT INTO `{cls.table}` ({col_list}) VALUES ({marks}) ON CONFLICT({keys}) DO UPDATE SET {sets}"
    elif m.kind == "update":
        sets = ", ".join(f"`{c}` = ?" for c in cols if c not in cls.primary_keys)
        where = " AND ".join(f"`{k}` = ?" for k in cls.primary_keys)
        sql = f"UPDATE `{cls.table}` SET {sets} WHERE {where}"
        byname = {p.column: p.name for p in cls.params}
        vals = ", ".join([f"row.{byname[c]}" for c in cols if c not in cls.primary_keys]
                         + [f"row.{byname[k]}" for k in cls.primary_keys])
    else:
        where = " AND ".join(f"`{k}` = ?" for k in cls.primary_keys)
        sql = f"DELETE FROM `{cls.table}` WHERE {where}"
        byname = {p.column: p.name for p in cls.params}
        vals = ", ".join(f"row.{byname[k]}" for k in cls.primary_keys)
    rows = pname if many else f"listOf({pname})"
    statements = f'{rows}.map {{ row -> "{sql}" to listOf<Any?>({vals}) }}'
    ret = m.ret
    if ret == "Unit":
        return f"CoreDb.execEach({statements})"
    if ret == "List<Long>":
        return f"CoreDb.execEach({statements}).rowids"
    if ret == "Long":
        return f"CoreDb.execEach({statements}).rowids.firstOrNull() ?: -1L"
    if ret == "Int":
        return f"CoreDb.execEach({statements}).total"
    raise ValueError(f"{m.name}: write returning {ret}")


def generate() -> str:
    classes = parse_classes()
    methods = parse_methods()
    used: set[str] = set()
    out = [
        "// GENERATED by Tools/gen_core_dao.py from WhoopDao.kt and DeviceRegistryDao.kt. Do not edit; run the script.",
        "package com.noop.data",
        "",
        "import com.noop.core.CoreDb",
        "import kotlinx.coroutines.flow.Flow",
        "",
        "/**",
        " * Fork (DX23876), Android without Room: [WhoopDao] answered by the shared core's store ([CoreDb]). Each",
        " * statement is the one Room ran; the tables and columns are the core's own (`schema_oracle.json`).",
        " */",
        "class CoreWhoopDao : WhoopDao {",
    ]
    consts = []
    nested = {c.name: c.qualified for c in classes.values() if c.qualified != c.name}

    def qualify(t: str) -> str:
        for short, full in nested.items():
            t = re.sub(rf"(?<![.\w]){short}\b", full, t)
        return t

    for m in methods:
        m.ret = qualify(m.ret)
        m.params = [(n, qualify(t)) for n, t in m.params]
        sig_params = ", ".join(f"{n}: {t}" for n, t in m.params)
        flow = m.ret.startswith("Flow<")
        prefix = "override suspend fun" if m.suspend else "override fun"
        if m.kind == "query":
            consts.append(f"    private val SQL_{m.name}: String = {m.sql}")
            body = query_body(m, classes, used)
        else:
            body = write_body(m, classes, used)
        ret = "" if m.ret == "Unit" else f": {m.ret}"
        if m.ret == "Unit" and m.kind == "query":
            out.append(f"    {prefix} {m.name}({sig_params}) {{ {body} }}")
        elif m.ret == "Unit":
            out.append(f"    {prefix} {m.name}({sig_params}) {{ {body} }}")
        else:
            out.append(f"    {prefix} {m.name}({sig_params}){ret} = {body}")
    out.append("")
    out.append("    private companion object {")
    out.extend("    " + c for c in consts)
    out.append("    }")
    out.append("}")
    out.append("")
    for name in sorted(used):
        out.append(mapper(classes[name]))
        out.append("")
    return "\n".join(out)


def main() -> int:
    text = generate()
    if "--check" in sys.argv:
        if OUT.read_text(encoding="utf-8") != text:
            print("CoreWhoopDao.kt is out of date: run python3 Tools/gen_core_dao.py", file=sys.stderr)
            return 1
        return 0
    OUT.write_text(text, encoding="utf-8")
    print(f"wrote {OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
