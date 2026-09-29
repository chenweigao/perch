#!/usr/bin/env python3
"""Summarize xctrace time-profile XML; inclusive stack weights overlap, not FPS."""
import argparse
from collections import Counter
import json
import xml.etree.ElementTree as ET

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("xml")
parser.add_argument("--after", type=float, default=0, help="Exclude startup seconds")
parser.add_argument("--before", type=float, default=float("inf"), help="Stop at the end of a measured interval")
args = parser.parse_args()
if args.before <= args.after:
    parser.error("--before must be later than --after")
root = ET.parse(args.xml).getroot()
refs = {node.attrib["id"]: node for node in root.iter() if "id" in node.attrib}


def resolve(node):
    return refs[node.attrib["ref"]] if "ref" in node.attrib else node


all_ms = main_ms = 0
samples = main_samples = 0
inclusive, app_frames, leaves = Counter(), Counter(), Counter()
contexts = Counter()
bins = Counter()
examples = {}


def stack_context(names):
    # First match wins: each sample has exactly one bucket. These identify
    # synchronous stack contexts, not the owner of deferred framework work.
    rules = [
        ("row_measure", ("ConversationEntryController.measure(width:",)),
        ("row_create", ("ConversationEntryController.init(",)),
        ("transcript_other", ("ConversationDocumentView.", "ConversationEntryController.", "ReplyTextView.", "ReplyDocument.")),
        ("sidebar", ("SessionRowChrome.", "SessionSidebarRow.", "WorkbenchSidebar.", "WorkspaceSidebarShell.", "SidebarSection.")),
        ("composer", ("ComposerToolbarLayout.", "ComposerEditor.", "DraftTextView.", "NativeComposerView.")),
        ("framework_graph_remaining", ("AG::Graph::UpdateStack::update",)),
        ("framework_layout_remaining", ("_layoutSubtreeWithOldSize",)),
    ]
    for label, patterns in rules:
        if any(pattern in name for name in names for pattern in patterns):
            return label
    return "other"
for row in root.findall(".//row"):
    cells = list(row)
    timestamp = int(resolve(cells[0]).text) / 1e9
    if timestamp < args.after or timestamp >= args.before:
        continue
    thread = resolve(cells[1]).attrib.get("fmt", "")
    weight = int(resolve(cells[5]).text) / 1e6
    samples += 1
    all_ms += weight
    if "Main Thread" not in thread:
        continue
    main_samples += 1
    main_ms += weight
    bins[int(timestamp)] += weight
    frames = [resolve(frame) for frame in resolve(cells[6])]
    names = [frame.attrib.get("name", "unknown") for frame in frames]
    contexts[stack_context(names)] += weight
    if names:
        leaves[names[0]] += weight
    for name in set(names):
        inclusive[name] += weight
    own_names = set()
    for frame in frames:
        binary = frame.find("binary")
        if binary is not None and resolve(binary).attrib.get("name") in ("NavigationPreview", "PerchDemo", "WorkbenchPreview", "AgentWorkbench", "NativeAcceptance"):
            own_names.add(frame.attrib.get("name", "unknown"))
    for name in own_names:
        app_frames[name] += weight
        examples.setdefault(name, names)

top_app = app_frames.most_common(35)
print(json.dumps({
    "after_s": args.after, "before_s": args.before if args.before != float("inf") else None, "sample_rows": samples, "main_sample_rows": main_samples,
    "all_threads_sampled_cpu_ms": round(all_ms, 3), "main_sampled_cpu_ms": round(main_ms, 3),
    "main_cpu_ms_per_second": dict(sorted(bins.items())),
    "main_inclusive_top": inclusive.most_common(40), "main_leaf_top": leaves.most_common(25),
    "main_stack_context_partition_ms": dict(contexts.most_common()),
    "partition_note": "First matching context: row_measure, row_create, transcript_other, sidebar, composer, framework_graph_remaining, framework_layout_remaining, other. Buckets sum to main CPU, but deferred framework work cannot be assigned to a feature from these stacks.",
    "main_app_inclusive_top": top_app,
    "app_stack_examples": {name: examples[name] for name, _ in top_app[:10]},
    "note": "Inclusive CPU sample weights overlap. Sampling excludes waiting threads; these are neither wall-clock latency nor display frame timings."
}, indent=2))
