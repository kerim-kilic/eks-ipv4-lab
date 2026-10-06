#!/usr/bin/env python3
"""Copies captures/raw to captures/scrubbed with account, resource and public address details replaced.

Each real value gets a stable placeholder (subnet-EXAMPLE1, 203.0.113.1, ...), so readers can still follow which
resource is which across files. Private addresses (10.x, 100.64.x) stay: they are the subject of the lab and say
nothing about anyone's network.

The node logs from the end of each step (2-full/logs/ipamd-*.log and cni-plugin-*.log) are written gzipped: they are
mostly the CNI retrying the same request, and they contain the first-failure logs, which stay plain text.
"""

import gzip
import ipaddress
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / "captures" / "raw"
OUT = ROOT / "captures" / "scrubbed"

KEEP_NETWORKS = [
    ipaddress.ip_network(n)
    for n in ("10.0.0.0/8", "100.64.0.0/10", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "127.0.0.0/8",
              "0.0.0.0/8", "203.0.113.0/24")
]

mappings: dict[str, dict[str, str]] = {}


def placeholder(kind: str, value: str, fmt) -> str:
    table = mappings.setdefault(kind, {})
    if value not in table:
        table[value] = fmt(len(table) + 1)
    return table[value]


def public_ip(match: re.Match) -> str:
    text = match.group(0)
    try:
        ip = ipaddress.ip_address(text)
    except ValueError:
        return text
    if any(ip in net for net in KEEP_NETWORKS):
        return text
    return placeholder("ip", text, lambda n: f"203.0.113.{n}")


RULES = [
    # Principals and sessions, before the account ID rule eats their digits.
    (re.compile(r"arn:aws:(iam|sts)::\d{12}:(user|assumed-role|federated-user)/[^\s\"',]+"),
     lambda m: placeholder("principal", m.group(0), lambda n: f"arn:aws:{m.group(1)}::111122223333:{m.group(2)}/EXAMPLE{n}")),
    (re.compile(r"\b(AROA|AIDA|AKIA|ASIA|AGPA|ANPA)[A-Z0-9]{12,}(:[^\s\"',]+)?"),
     lambda m: placeholder("unique-id", m.group(0), lambda n: f"AROAEXAMPLE{n}")),
    (re.compile(r"\b\d{12}\b"), lambda m: "111122223333"),
    # Cluster endpoint and OIDC issuer carry a per-cluster ID.
    (re.compile(r"\b[0-9A-F]{32}\b"), lambda m: placeholder("cluster-id", m.group(0), lambda n: f"EXAMPLE{n:027d}")),
    (re.compile(r"\b(vpc|subnet|eni|i|sg|nat|eipalloc|eipassoc|igw|rtb|rtbassoc|lt|acl|attach|vpc-cidr-assoc|"
                r"subnet-cidr-assoc|ami|vol|snap)-[0-9a-f]{8,17}\b"),
     lambda m: placeholder(m.group(1), m.group(0), lambda n: f"{m.group(1)}-EXAMPLE{n}")),
    (re.compile(r"\bec2-\d+-\d+-\d+-\d+\.[a-z0-9.-]+\.amazonaws\.com\b"),
     lambda m: placeholder("public-dns", m.group(0), lambda n: f"ec2-EXAMPLE{n}.compute.amazonaws.com")),
    (re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b"), public_ip),
]

LEFTOVERS = [re.compile(r"\b(?!111122223333)\d{12}\b"), re.compile(r"\b[0-9A-F]{32}\b")]


def scrub(text: str) -> str:
    for pattern, repl in RULES:
        text = pattern.sub(repl, text)
    return text


def compress(path: Path) -> bool:
    return path.parent.name == "logs" and path.parent.parent.name == "2-full" and \
        path.name.startswith(("ipamd-", "cni-plugin-"))


def write(dst: Path, text: str, gzipped: bool) -> None:
    if not gzipped:
        dst.write_text(text)
        return
    # mtime=0 so an unchanged log gives a byte-identical file, and git sees no change.
    with open(dst.with_name(dst.name + ".gz"), "wb") as raw, gzip.GzipFile(fileobj=raw, mode="wb", mtime=0) as gz:
        gz.write(text.encode())


def main() -> int:
    if not RAW.is_dir():
        print("Nothing to scrub: captures/raw does not exist.", file=sys.stderr)
        return 1
    if OUT.exists():
        shutil.rmtree(OUT)

    files = 0
    leftovers = 0
    for src in sorted(p for p in RAW.rglob("*") if p.is_file()):
        dst = OUT / src.relative_to(RAW)
        dst.parent.mkdir(parents=True, exist_ok=True)
        clean = scrub(src.read_text(errors="replace"))
        write(dst, clean, compress(src))
        files += 1
        leftovers += sum(len(p.findall(clean)) for p in LEFTOVERS)

    replaced = {kind: len(values) for kind, values in mappings.items()}
    print(f"Scrubbed {files} files into captures/scrubbed. Distinct values replaced: {replaced}")
    # Counts only, so nothing sensitive is printed.
    if leftovers:
        print(f"WARNING: {leftovers} suspicious values remain. Check before committing.", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
