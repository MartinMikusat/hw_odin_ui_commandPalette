package command_palette

import "core:mem"
import "core:strings"
import mem_virtual "core:mem/virtual"
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
SESSION_MINIMUM_BLOCK_SIZE :: uint(mem.Megabyte)
SESSION_COMMIT_SIZE :: uint(64 * mem.Kilobyte)

State :: struct {
	allocator:      mem.Allocator,
	session:        mem_virtual.Arena,
	search:         match_sorter.Search_Context,
	entries:        [dynamic]Entry,
	results:        [dynamic]Result,
	query_bytes:    [dynamic]u8,
	ranked_indices: [dynamic]int,
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

state_init :: proc(
	state: ^State,
	allocator := context.allocator,
	search_reserve_size := uint(mem.Gigabyte),
	search_commit_size := uint(mem.Megabyte),
) -> mem.Allocator_Error {
	assert(state != nil)
	state^ = State{allocator = allocator, selected = -1}
	state.results = make([dynamic]Result, allocator)
	state.query_bytes = make([dynamic]u8, allocator)
	state.ranked_indices = make([dynamic]int, allocator)
	if error := mem_virtual.arena_init_growing(&state.session, SESSION_MINIMUM_BLOCK_SIZE); error != nil {
		delete(state.results)
		delete(state.query_bytes)
		delete(state.ranked_indices)
		state^ = {}
		return error
	}
	state.session.minimum_block_size = SESSION_MINIMUM_BLOCK_SIZE
	state.session.default_commit_size = SESSION_COMMIT_SIZE
	if error := match_sorter.search_context_init(
		&state.search,
		search_reserve_size,
		search_commit_size,
	); error != nil {
		mem_virtual.arena_destroy(&state.session)
		delete(state.results)
		delete(state.query_bytes)
		delete(state.ranked_indices)
		state^ = {}
		return error
	}
	return nil
}

close :: proc(state: ^State) {
	if state == nil {return}
	clear(&state.results)
	clear(&state.ranked_indices)
	state.entries = nil
	mem_virtual.arena_free_all(&state.session)
	clear(&state.query_bytes)
	state.active_context = 0
	state.selected = -1
	state.open = false
}

state_destroy :: proc(state: ^State) {
	if state == nil {return}
	close(state)
	delete(state.results)
	delete(state.query_bytes)
	delete(state.ranked_indices)
	match_sorter.search_context_destroy(&state.search)
	mem_virtual.arena_destroy(&state.session)
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

entries_have_valid_utf8 :: proc(entries: []Entry) -> bool {
	for entry in entries {
		if !match_sorter.valid_utf8(entry.title) ||
		   !match_sorter.valid_utf8(entry.subtitle) ||
		   !match_sorter.valid_utf8(entry.category) {
			return false
		}
		for keyword in entry.keywords {
			if !match_sorter.valid_utf8(keyword) {return false}
		}
	}
	return true
}

first_available_result :: proc(state: ^State) -> int {
	for result, index in state.results {
		if result.available {return index}
	}
	return -1
}

rebuild_results :: proc(state: ^State) -> match_sorter.Search_Error {
	if len(state.query_bytes) == 0 {
		clear(&state.ranked_indices)
		clear(&state.results)
		for &entry in state.entries {
			append(&state.results, Result{
				entry = &entry,
				available = context_matches(state.active_context, entry.contexts),
			})
		}
	} else {
		keys := []match_sorter.Key(Entry) {
			{getter = entry_title},
			{getter = entry_subtitle},
			{getter = entry_category},
			{getter = entry_keywords},
		}
		search_error := match_sorter.match_indices_into(
			&state.search,
			state.entries[:],
			string(state.query_bytes[:]),
			match_sorter.Options(Entry){keys = keys},
			&state.ranked_indices,
		)
		if search_error != .None {return search_error}
		clear(&state.results)
		for index in state.ranked_indices {
			entry := &state.entries[index]
			append(&state.results, Result{
				entry = entry,
				available = context_matches(state.active_context, entry.contexts),
			})
		}
	}
	state.selected = first_available_result(state)
	return .None
}

open :: proc(
	state: ^State,
	entries: []Entry,
	active_context: Context_Mask,
) -> match_sorter.Search_Error {
	assert(state != nil && state.search.initialized, "Call command_palette.state_init before open")
	if !entries_have_valid_utf8(entries) {return .Invalid_UTF8}
	close(state)
	session_allocator := mem_virtual.arena_allocator(&state.session)
	state.entries = make([dynamic]Entry, 0, len(entries), session_allocator)
	for entry in entries {append(&state.entries, clone_entry(entry, session_allocator))}
	state.active_context = active_context
	state.open = true
	return rebuild_results(state)
}

is_open :: proc(state: ^State) -> bool {
	return state != nil && state.open
}

query :: proc(state: ^State) -> string {
	if state == nil || !state.open {return ""}
	return string(state.query_bytes[:])
}

set_query :: proc(
	state: ^State,
	value: string,
) -> match_sorter.Search_Error {
	if state == nil || !state.open {return .None}
	if !match_sorter.valid_utf8(value) ||
	   !entries_have_valid_utf8(state.entries[:]) {
		return .Invalid_UTF8
	}
	resize(&state.query_bytes, len(value))
	copy(state.query_bytes[:], transmute([]u8)value)
	return rebuild_results(state)
}

set_context :: proc(state: ^State, active_context: Context_Mask) {
	if state == nil || !state.open {return}
	state.active_context = active_context
	search_error := rebuild_results(state)
	assert(search_error == .None, "Validated command palette state became invalid")
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
