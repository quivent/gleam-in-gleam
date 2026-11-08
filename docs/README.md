# Interactive roadmap

Open [roadmap.html](roadmap.html) from a checkout in your browser. The entire page
works offline: its data, styles and browser script are embedded. GitHub displays
HTML as source; download/open the checkout file to use the interactive view.

From the repository root, a local preview is also available with:

```sh
python3 -m http.server 8765 --bind 127.0.0.1 --directory .
```

Then open <http://127.0.0.1:8765/docs/roadmap.html> on that same machine. Stop the
preview with Ctrl-C. This is a loopback preview, not a public deployment.

## Interaction

* Expand any of eight workstreams. Switch between Spec, Acceptance and Evidence.
* Search across the actual spec text or filter the four core/four expansion lanes.
* Follow the next-action button and related-stage links.
* Mark acceptance criteria for your own review and keep notes in this browser.
* Export the review as JSON, including its compiler baseline reference.

Review marks and notes do not change verified status, the verified first-milestone indicator,
shared tasks or source files. They are browser-local annotations, with no upload
or synchronization service. Storage-blocked mode supports in-memory review and
export. A no-JavaScript fallback links to the complete text roadmap.

## Sources and updates

[roadmap.json](roadmap.json) is the versioned input for the eight interactive specs.
It contains explicit stage status, scope, maturity, acceptance criteria, next
steps, related stages and evidence paths. The first delivered stage links to
[NATIVE_CLI_SPEC.md](../NATIVE_CLI_SPEC.md); the completed scale work links to
[FULL_SIZE_RELIABILITY_SPEC.md](../FULL_SIZE_RELIABILITY_SPEC.md). Extension stages remain
spec outlines to refine when work starts.

[roadmap.template.html](roadmap.template.html) supplies the interface.
[The generator](../tools/render_roadmap.py) validates the eight stages and local
links, checks the two compiler evidence snapshots agree, and derives displayed
metrics from the actual receipts. The resulting HTML is a portable snapshot, not
a live build monitor. Update the source revision and statuses when fresh compiler
results qualify a new baseline. The text roadmap remains in [ROADMAP.md](../ROADMAP.md).

```sh
python3 tools/render_roadmap.py
python3 tools/render_roadmap.py --check
```

Browser verification is development-only and uses an existing Playwright/Chromium
installation. Optional PLAYWRIGHT_MODULE and PLAYWRIGHT_CHROMIUM_EXECUTABLE point
to tools outside this repository; no compiler/runtime package is added.

```sh
node test/roadmap-browser.mjs evidence/roadmap-ui-verification.json
```

The browser check covers real filtering, keyboard/touch navigation, review
persistence/export, inert note text, storage errors, no-JavaScript fallback,
320/390/768px layouts and absence of external HTTP requests. Generated screenshots
and example review exports stay under ignored out/roadmap-preview/.

The current optimization increment and remaining allocator design are in
[REGISTER_SPILL_SPEC.md](../REGISTER_SPILL_SPEC.md). Core self-hosting stays
verified; the optimization workstream is partial.
