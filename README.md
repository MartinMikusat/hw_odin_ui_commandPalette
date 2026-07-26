# Odin UI Command Palette

A renderer-independent Odin library for searchable, context-aware application commands and data.

## AI-assisted development disclosure

Models used:

- **GPT-5.6-Sol**

The package uses `hw_odin_matchSorter` to rank entry titles, subtitles, categories, and keywords. Applications supply opaque entry identifiers and context bits. The package never executes application code or draws interface elements.

## Integration

Initialize one state object and destroy it during application shutdown:

```odin
import command_palette "command_palette:."

palette: command_palette.State
assert(command_palette.state_init(&palette) == nil)
defer command_palette.state_destroy(&palette)
```

Each entry contains one context condition. The application defines the meaning of each bit.

```odin
CONTEXT_CREATE :: command_palette.Context_Mask(1 << 0)
CONTEXT_PLAYER :: command_palette.Context_Mask(1 << 1)

entries := []command_palette.Entry{
	{
		id = 1,
		title = "Mark In",
		category = "Command",
		contexts = {all = CONTEXT_CREATE | CONTEXT_PLAYER},
		unavailable_reason = "Available with a loaded source in Create mode",
	},
}

command_palette.open(&palette, entries, CONTEXT_CREATE | CONTEXT_PLAYER)
```

`visible_results` returns borrowed results in match-sorter order. A disabled result remains visible with its reason. Selection procedures skip disabled results.

The default shortcut is Ctrl-K. Supply `Config.shortcut` to use another ASCII key and exact modifier set. Translate platform events into the package modifier set before calling `shortcut_matches`.

## Ownership

`open` copies every entry string and keyword. The caller can release its snapshot after the call. Results and their entry pointers remain valid until the next state mutation.

One state supports sequential searches. Use one state per thread. The package owns one match-sorter search context and releases it in `state_destroy`.

## Verification

```sh
odin test . -collection:match_sorter=../hw_odin_matchSorter
```
