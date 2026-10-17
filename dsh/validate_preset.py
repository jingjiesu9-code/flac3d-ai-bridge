"""Validate a locally authored agent preset before it is installed.

Checks the two things that make a preset silently useless rather than loudly
broken: a composition that is not a named-plugin-row list, and a skill whose
frontmatter the skill loader cannot read.

`!!js` is a loader-side escape hatch, so the YAML loader here maps unknown tags
back to their source text instead of failing on them.

Usage:
    python validate_preset.py <preset_dir>
"""
import io
import os
import sys

import yaml


class PermissiveLoader(yaml.SafeLoader):
    pass


def _unknown(loader, tag_suffix, node):
    if isinstance(node, yaml.ScalarNode):
        return {"__tag__": tag_suffix, "value": loader.construct_scalar(node)}
    if isinstance(node, yaml.SequenceNode):
        return loader.construct_sequence(node)
    return loader.construct_mapping(node)


PermissiveLoader.add_multi_constructor("", _unknown)
PermissiveLoader.add_multi_constructor("tag:yaml.org,2002:", _unknown)

errors = []
warnings = []


def check(cond, msg):
    if not cond:
        errors.append(msg)


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    root = sys.argv[1]

    # --- preset.yml -------------------------------------------------------
    pj = os.path.join(root, "preset.yml")
    check(os.path.isfile(pj), "preset.yml missing")
    if os.path.isfile(pj):
        with io.open(pj, "r", encoding="utf-8") as fh:
            meta = yaml.load(fh, Loader=PermissiveLoader)
        check(isinstance(meta, dict), "preset.yml is not a mapping")
        if isinstance(meta, dict):
            check(bool(meta.get("name")), "preset.yml has no display name")
            check(bool(meta.get("description")), "preset.yml has no description")
            print("preset.yml      name=%r" % meta.get("name"))

    # --- agent.cordis.yml -------------------------------------------------
    ac = os.path.join(root, "agent.cordis.yml")
    check(os.path.isfile(ac), "agent.cordis.yml missing")
    if os.path.isfile(ac):
        with io.open(ac, "r", encoding="utf-8") as fh:
            rows = yaml.load(fh, Loader=PermissiveLoader)
        check(isinstance(rows, list), "agent.cordis.yml is not a list of plugin rows")
        if isinstance(rows, list):
            ids, names = [], []
            for i, row in enumerate(rows):
                if not isinstance(row, dict):
                    errors.append("row %d is not a mapping" % i)
                    continue
                if not row.get("id"):
                    errors.append("row %d has no id" % i)
                if not row.get("name") and not row.get("group"):
                    errors.append("row %d has no name (id=%r)" % (i, row.get("id")))
                if row.get("id") in ids:
                    errors.append("duplicate row id %r" % row.get("id"))
                ids.append(row.get("id"))
                names.append(row.get("name"))
            print("agent.cordis.yml %d rows, %d unique ids" % (len(rows), len(set(map(str, ids)))))

            for want in ("persona", "skill-filesystem", "tool-skill"):
                check(want in ids, "expected row %r is absent" % want)

            # The preset must actually wire its own skills/ directory.
            for row in rows:
                if row.get("id") == "skill-filesystem":
                    cfg = row.get("config") or {}
                    if not cfg.get("customSkillDirs"):
                        errors.append(
                            "skill-filesystem has no customSkillDirs -- "
                            "the preset's own skills/ would never load")
                    else:
                        print("customSkillDirs wired: %r" % (cfg["customSkillDirs"],))

    # --- skills -----------------------------------------------------------
    sk_root = os.path.join(root, "skills")
    if not os.path.isdir(sk_root):
        warnings.append("no skills/ directory")
    else:
        found = sorted(
            d for d in os.listdir(sk_root)
            if os.path.isfile(os.path.join(sk_root, d, "SKILL.md"))
        )
        check(bool(found), "skills/ exists but contains no <name>/SKILL.md")
        for name in found:
            p = os.path.join(sk_root, name, "SKILL.md")
            with io.open(p, "r", encoding="utf-8") as fh:
                text = fh.read()
            if not text.startswith("---"):
                errors.append("skills/%s/SKILL.md has no frontmatter" % name)
                continue
            end = text.find("\n---", 3)
            if end < 0:
                errors.append("skills/%s/SKILL.md frontmatter is unterminated" % name)
                continue
            fm = yaml.load(text[3:end], Loader=PermissiveLoader) or {}
            check(fm.get("name") == name,
                  "skills/%s/SKILL.md frontmatter name=%r does not match its directory"
                  % (name, fm.get("name")))
            desc = fm.get("description") or ""
            check(desc.startswith("Use when"),
                  "skills/%s/SKILL.md description should start with 'Use when'" % name)
            print("skill           %-24s desc=%d chars" % (name, len(desc)))

    # --- report -----------------------------------------------------------
    for w in warnings:
        print("WARN  " + w)
    for e in errors:
        print("FAIL  " + e)
    print("\n%s" % ("INVALID: %d problem(s)" % len(errors) if errors else "VALID"))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
