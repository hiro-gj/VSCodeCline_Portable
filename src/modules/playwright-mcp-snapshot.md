# Rules for Using Playwright MCP `browser_snapshot`

Calling `browser_snapshot` directly on pages with a large number of elements (such as full account lists or unfiltered search results) returns multi-MB snapshots into the conversation history (`tool_result`), causing VSCode to freeze and crash. You MUST strictly follow these operational rules:

- **Use the `filename` parameter**: When calling `browser_snapshot` (especially on pages that may contain large tables, lists, or many DOM elements), ALWAYS specify the `filename` argument so the snapshot output is saved to a file instead of being returned directly into the conversation history (`tool_result`). Then, inspect only the necessary sections using `search_codebase` or `read_files` (with `start_line` / `end_line` line ranges).
- **Use `browser_find` or `target`**: Instead of capturing a full-page snapshot, prefer using `browser_find` to search for specific text or specifying a `target` selector in `browser_snapshot` to narrow the snapshot down to only the relevant element.
