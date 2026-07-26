package command_palette

import "core:mem"
import "core:strings"
import match_sorter "match_sorter:."

Entry_ID :: distinct u64
Context_Mask :: distinct u64

Context_Condition :: struct {
	all:  Context_Mask,
	any:  Context_Mask,
	none: Context_Mask,
}

Entry :: struct {
	id:                   Entry_ID,
	title:                string,
	subtitle:             string,
	category:             string,
	keywords:             []string,
	contexts:             Context_Condition,
	unavailable_reason:   string,
}

Result :: struct {
	entry:     ^Entry,
	available: bool,
}

Modifier :: enum {
	Shift,
	Control,
	Option,
	Command,
}

Modifier_Set :: bit_set[Modifier]

Shortcut :: struct {
	key:       u8,
	modifiers: Modifier_Set,
}

Config :: struct {
	shortcut: Shortcut,
}

DEFAULT_SHORTCUT :: Shortcut{key = 'k', modifiers = {.Control}}

State :: struct {
	allocator:      mem.Allocator,
	search:         match_sorter.Search_Context,
	entries:        [dynamic]Entry,
	results:        [dynamic]Result,
	query_text:     string,
	active_context: Context_Mask,
	selected:       int,
	open:           bool,
}

context_matches :: proc(active: Context_Mask, condition: Context_Condition) -> bool {
	active_bits := u64(active)
	all_bits := u64(condition.all)
	any_bits := u64(condition.any)
	none_bits := u64(condition.none)
	if active_bits & all_bits != all_bits {return false}
	if any_bits != 0 && active_bits & any_bits == 0 {return false}
	return active_bits & none_bits == 0
}

resolved_shortcut :: proc(config: Config) -> Shortcut {
	if config.shortcut.key == 0 {return DEFAULT_SHORTCUT}
	return config.shortcut
}

shortcut_matches :: proc(config: Config, key: u8, modifiers: Modifier_Set) -> bool {
	shortcut := resolved_shortcut(config)
	normalized := key
	shortcut_key := shortcut.key
	if normalized >= 'A' && normalized <= 'Z' {normalized += 'a' - 'A'}
	if shortcut_key >= 'A' && shortcut_key <= 'Z' {shortcut_key += 'a' - 'A'}
	return normalized == shortcut_key && modifiers == shortcut.modifiers
}

state_init :: proc(state: ^State, allocator := context.allocator) -> mem.Allocator_Error {
	assert(state != nil)
	state^ = State{allocator = allocator, selected = -1}
	state.entries = make([dynamic]Entry, allocator)
	state.results = make([dynamic]Result, allocator)
	return match_sorter.search_context_init(&state.search)
}

delete_entry :: proc(entry: ^Entry, allocator: mem.Allocator) {
	delete(entry.title, allocator)
	delete(entry.subtitle, allocator)
	delete(entry.category, allocator)
	delete(entry.unavailable_reason, allocator)
	for keyword in entry.keywords {delete(keyword, allocator)}
	delete(entry.keywords, allocator)
	entry^ = {}
}

clear_entries :: proc(state: ^State) {
	for &entry in state.entries {delete_entry(&entry, state.allocator)}
	clear(&state.entries)
}

close :: proc(state: ^State) {
	if state == nil {return}
	clear_entries(state)
	clear(&state.results)
	delete(state.query_text, state.allocator)
	state.query_text = ""
	state.active_context = 0
	state.selected = -1
	state.open = false
}

state_destroy :: proc(state: ^State) {
	if state == nil {return}
	close(state)
	delete(state.entries)
	delete(state.results)
	match_sorter.search_context_destroy(&state.search)
	state^ = {}
}

clone_entry :: proc(entry: Entry, allocator: mem.Allocator) -> Entry {
	copy := entry
	copy.title = strings.clone(entry.title, allocator)
	copy.subtitle = strings.clone(entry.subtitle, allocator)
	copy.category = strings.clone(entry.category, allocator)
	copy.unavailable_reason = strings.clone(entry.unavailable_reason, allocator)
	copy.keywords = make([]string, len(entry.keywords), allocator)
	for keyword, index in entry.keywords {
		copy.keywords[index] = strings.clone(keyword, allocator)
	}
	return copy
}

entry_title :: proc(entry: ^Entry) -> match_sorter.Extracted_Values {
	return match_sorter.single_value(entry.title)
}

entry_subtitle :: proc(entry: ^Entry) -> match_sorter.Extracted_Values {
	return match_sorter.single_value(entry.subtitle)
}

entry_category :: proc(entry: ^Entry) -> match_sorter.Extracted_Values {
	return match_sorter.single_value(entry.category)
}

entry_keywords :: proc(entry: ^Entry) -> match_sorter.Extracted_Values {
	return match_sorter.many_values(entry.keywords)
}

first_available_result :: proc(state: ^State) -> int {
	for result, index in state.results {
		if result.available {return index}
	}
	return -1
}

rebuild_results :: proc(state: ^State) {
	clear(&state.results)
	if len(state.query_text) == 0 {
		for &entry in state.entries {
			append(&state.results, Result{
				entry = &entry,
				available = context_matches(state.active_context, entry.contexts),
			})
		}
	} else {
		keys := []match_sorter.Typed_Key(Entry) {
			{getter = entry_title},
			{getter = entry_subtitle},
			{getter = entry_category},
			{getter = entry_keywords},
		}
		indices := match_sorter.match_indices(
			&state.search,
			state.entries[:],
			state.query_text,
			match_sorter.Typed_Options(Entry){keys = keys},
			state.allocator,
		)
		defer delete(indices, state.allocator)
		for index in indices {
			entry := &state.entries[index]
			append(&state.results, Result{
				entry = entry,
				available = context_matches(state.active_context, entry.contexts),
			})
		}
	}
	state.selected = first_available_result(state)
}

open :: proc(
	state: ^State,
	entries: []Entry,
	active_context: Context_Mask,
) {
	assert(state != nil && state.search.initialized, "Call command_palette.state_init before open")
	close(state)
	for entry in entries {append(&state.entries, clone_entry(entry, state.allocator))}
	state.active_context = active_context
	state.open = true
	rebuild_results(state)
}

is_open :: proc(state: ^State) -> bool {
	return state != nil && state.open
}

query :: proc(state: ^State) -> string {
	if state == nil || !state.open {return ""}
	return state.query_text
}

set_query :: proc(state: ^State, value: string) {
	if state == nil || !state.open {return}
	delete(state.query_text, state.allocator)
	state.query_text = strings.clone(value, state.allocator)
	rebuild_results(state)
}

set_context :: proc(state: ^State, active_context: Context_Mask) {
	if state == nil || !state.open {return}
	state.active_context = active_context
	rebuild_results(state)
}

visible_results :: proc(state: ^State) -> []Result {
	if state == nil || !state.open {return nil}
	return state.results[:]
}

selected_index :: proc(state: ^State) -> int {
	if state == nil || !state.open {return -1}
	return state.selected
}

select_result :: proc(state: ^State, index: int) -> bool {
	if state == nil || !state.open || index < 0 || index >= len(state.results) {return false}
	if !state.results[index].available {return false}
	state.selected = index
	return true
}

move_selection :: proc(state: ^State, direction: int) -> bool {
	if state == nil || !state.open || direction == 0 {return false}
	if len(state.results) == 0 {state.selected = -1; return false}
	step := 1
	if direction < 0 {step = -1}
	index := state.selected
	if index < 0 {index = step < 0 ? len(state.results) : -1}
	for {
		next := index + step
		if next < 0 || next >= len(state.results) {return false}
		index = next
		if state.results[index].available {
			state.selected = index
			return true
		}
	}
}

activate_result :: proc(state: ^State, index: int) -> (Entry_ID, bool) {
	if !select_result(state, index) {return 0, false}
	id := state.results[index].entry.id
	close(state)
	return id, true
}

activate_selected :: proc(state: ^State) -> (Entry_ID, bool) {
	if state == nil {return 0, false}
	return activate_result(state, state.selected)
}
