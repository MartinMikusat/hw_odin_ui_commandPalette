package command_palette

import "core:mem"
import "core:testing"

context_mask :: proc(bit: u64) -> Context_Mask {
	return Context_Mask(bit)
}

entry :: proc(
	id: u64,
	title: string,
	category := "Command",
	condition := Context_Condition{},
	reason := "",
	keywords: []string = nil,
) -> Entry {
	return {
		id = Entry_ID(id),
		title = title,
		category = category,
		keywords = keywords,
		contexts = condition,
		unavailable_reason = reason,
	}
}

@(test)
context_conditions_require_include_and_exclude_flags_test :: proc(t: ^testing.T) {
	create := context_mask(1 << 0)
	player := context_mask(1 << 1)
	busy := context_mask(1 << 2)
	condition := Context_Condition{
		all = Context_Mask(u64(create) | u64(player)),
		none = busy,
	}
	testing.expect(t, context_matches(Context_Mask(u64(create) | u64(player)), condition))
	testing.expect(t, !context_matches(create, condition))
	testing.expect(t, !context_matches(Context_Mask(u64(create) | u64(player) | u64(busy)), condition))
	testing.expect(t, context_matches(create, Context_Condition{any = Context_Mask(u64(create) | u64(player))}))
}

@(test)
empty_query_preserves_registration_order_and_disabled_rows_test :: proc(t: ^testing.T) {
	state: State
	testing.expect(t, state_init(&state) == nil)
	defer state_destroy(&state)
	create := context_mask(1)
	play := context_mask(2)
	entries := []Entry{
		entry(1, "Mark In", condition = Context_Condition{all = create}),
		entry(2, "Play Exercise", "Exercise", Context_Condition{all = play}, "Available in Play mode"),
		entry(3, "Open Data Folder"),
	}
	open(&state, entries, create)
	results := visible_results(&state)
	testing.expect_value(t, len(results), 3)
	testing.expect_value(t, results[0].entry.id, Entry_ID(1))
	testing.expect(t, !results[1].available)
	testing.expect_value(t, results[1].entry.unavailable_reason, "Available in Play mode")
	testing.expect_value(t, selected_index(&state), 0)
}

@(test)
match_sorter_searches_title_subtitle_category_and_keywords_test :: proc(t: ^testing.T) {
	state: State
	testing.expect(t, state_init(&state) == nil)
	defer state_destroy(&state)
	entries := []Entry{
		{id=1, title="Mark In", subtitle="Set the range start", category="Command"},
		{id=2, title="Breath Support", subtitle="Exercise from lesson", category="Exercise"},
		{id=3, title="Appoggio Lesson", category="Source", keywords=[]string{"abc123", "youtube"}},
	}
	open(&state, entries, 0)
	set_query(&state, "abc123")
	results := visible_results(&state)
	testing.expect_value(t, len(results), 1)
	testing.expect_value(t, results[0].entry.id, Entry_ID(3))
	set_query(&state, "range start")
	testing.expect_value(t, visible_results(&state)[0].entry.id, Entry_ID(1))
	set_query(&state, "exercise")
	testing.expect_value(t, visible_results(&state)[0].entry.id, Entry_ID(2))
}

@(test)
navigation_skips_disabled_results_test :: proc(t: ^testing.T) {
	state: State
	testing.expect(t, state_init(&state) == nil)
	defer state_destroy(&state)
	active := context_mask(1)
	disabled := Context_Condition{all = context_mask(2)}
	entries := []Entry{
		entry(1, "First"),
		entry(2, "Disabled", condition = disabled, reason = "Unavailable"),
		entry(3, "Third"),
	}
	open(&state, entries, active)
	testing.expect(t, move_selection(&state, 1))
	testing.expect_value(t, selected_index(&state), 2)
	testing.expect(t, move_selection(&state, -1))
	testing.expect_value(t, selected_index(&state), 0)
	testing.expect(t, !select_result(&state, 1))
	testing.expect_value(t, selected_index(&state), 0)
}

@(test)
all_disabled_results_have_no_selection_test :: proc(t: ^testing.T) {
	state: State
	testing.expect(t, state_init(&state) == nil)
	defer state_destroy(&state)
	entries := []Entry{
		entry(1, "One", condition = Context_Condition{all = context_mask(2)}),
		entry(2, "Two", condition = Context_Condition{all = context_mask(2)}),
	}
	open(&state, entries, context_mask(1))
	testing.expect_value(t, selected_index(&state), -1)
	testing.expect(t, !move_selection(&state, 1))
	_, activated := activate_selected(&state)
	testing.expect(t, !activated)
	testing.expect(t, is_open(&state))
}

@(test)
activation_returns_opaque_id_and_closes_test :: proc(t: ^testing.T) {
	state: State
	testing.expect(t, state_init(&state) == nil)
	defer state_destroy(&state)
	open(&state, []Entry{entry(42, "Open Data Folder")}, 0)
	id, activated := activate_selected(&state)
	testing.expect(t, activated)
	testing.expect_value(t, id, Entry_ID(42))
	testing.expect(t, !is_open(&state))
}

@(test)
query_and_entry_data_are_owned_by_state_test :: proc(t: ^testing.T) {
	state: State
	testing.expect(t, state_init(&state) == nil)
	defer state_destroy(&state)
	title := []u8{'S', 'o', 'u', 'r', 'c', 'e'}
	open(&state, []Entry{entry(1, string(title))}, 0)
	title[0] = 'X'
	testing.expect_value(t, visible_results(&state)[0].entry.title, "Source")
	query_input := []u8{'s', 'o', 'u'}
	set_query(&state, string(query_input))
	query_input[0] = 'x'
	testing.expect_value(t, query(&state), "sou")
}

@(test)
session_arena_resets_and_releases_extra_blocks_test :: proc(t: ^testing.T) {
	state: State
	testing.expect(t, state_init(&state) == nil)
	defer state_destroy(&state)
	initial_reserved := state.session.total_reserved
	large_title := make([]u8, int(2 * mem.Megabyte))
	defer delete(large_title)
	for &value in large_title {value = 'a'}
	open(&state, []Entry{entry(1, string(large_title))}, 0)
	testing.expect(t, state.session.total_used > 0)
	testing.expect(t, state.session.total_reserved > initial_reserved)
	close(&state)
	testing.expect_value(t, state.session.total_used, uint(0))
	testing.expect_value(t, state.session.total_reserved, initial_reserved)
	open(&state, []Entry{entry(2, "Reopened")}, 0)
	testing.expect_value(t, visible_results(&state)[0].entry.id, Entry_ID(2))
}

@(test)
query_results_and_ranked_indices_reuse_capacity_test :: proc(t: ^testing.T) {
	state: State
	testing.expect(t, state_init(&state) == nil)
	defer state_destroy(&state)
	entries := []Entry{
		entry(1, "hello"),
		entry(2, "hey"),
		entry(3, "help"),
		entry(4, "sup"),
	}
	open(&state, entries, 0)
	results_buffer := raw_data(state.results[:])
	results_capacity := cap(state.results)
	set_query(&state, "h")
	set_query(&state, "hello")
	query_buffer := raw_data(state.query_bytes[:])
	query_capacity := cap(state.query_bytes)
	ranked_buffer := raw_data(state.ranked_indices[:])
	ranked_capacity := cap(state.ranked_indices)
	set_query(&state, "he")
	testing.expect(t, raw_data(state.results[:]) == results_buffer)
	testing.expect_value(t, cap(state.results), results_capacity)
	testing.expect(t, raw_data(state.query_bytes[:]) == query_buffer)
	testing.expect_value(t, cap(state.query_bytes), query_capacity)
	testing.expect(t, raw_data(state.ranked_indices[:]) == ranked_buffer)
	testing.expect_value(t, cap(state.ranked_indices), ranked_capacity)
	close(&state)
	testing.expect_value(t, len(state.query_bytes), 0)
	testing.expect_value(t, cap(state.query_bytes), query_capacity)
	testing.expect_value(t, len(state.results), 0)
	testing.expect_value(t, cap(state.results), results_capacity)
	testing.expect_value(t, len(state.ranked_indices), 0)
	testing.expect_value(t, cap(state.ranked_indices), ranked_capacity)
}

@(test)
custom_search_reservation_sizes_are_applied_test :: proc(t: ^testing.T) {
	state: State
	reserve_size := uint(64 * mem.Megabyte)
	commit_size := uint(64 * mem.Kilobyte)
	testing.expect(t, state_init(
		&state,
		search_reserve_size = reserve_size,
		search_commit_size = commit_size,
	) == nil)
	defer state_destroy(&state)
	testing.expect_value(t, state.search.scratch.total_reserved, reserve_size)
	testing.expect_value(t, state.search.scratch.curr_block.committed, commit_size)
}

@(test)
shortcut_defaults_to_exact_control_k_and_can_be_configured_test :: proc(t: ^testing.T) {
	testing.expect(t, shortcut_matches(Config{}, 'K', {.Control}))
	testing.expect(t, !shortcut_matches(Config{}, 'k', {.Control, .Shift}))
	custom := Config{shortcut = {key = 'P', modifiers = {.Command, .Shift}}}
	testing.expect(t, shortcut_matches(custom, 'P', {.Command, .Shift}))
	testing.expect(t, !shortcut_matches(custom, 'p', {.Command}))
}
