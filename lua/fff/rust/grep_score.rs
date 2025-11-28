use crate::types::{GrepItem, Score};
use neo_frizbee::Scoring;
use rayon::prelude::*;

pub struct GrepScoringContext<'a> {
    pub query: &'a str,
    pub max_results: usize,
    pub max_typos: u16,
    pub max_threads: usize,
}

/// Score grep results with fuzzy matching on path and line content
pub fn match_and_score_grep_items(
    items: &[GrepItem],
    context: &GrepScoringContext,
) -> (Vec<GrepItem>, Vec<Score>, usize) {
    if items.is_empty() {
        return (vec![], vec![], 0);
    }

    let has_uppercase_letter = context.query.chars().any(|c| c.is_uppercase());
    let options = neo_frizbee::Config {
        prefilter: true,
        max_typos: Some(context.max_typos),
        sort: false,
        scoring: Scoring {
            capitalization_bonus: if has_uppercase_letter { 8 } else { 0 },
            matching_case_bonus: if has_uppercase_letter { 4 } else { 0 },
            ..Default::default()
        },
    };

    // Create haystack: combine path and line content for fuzzy matching
    let haystack: Vec<_> = items
        .iter()
        .map(|item| {
            format!(
                "{} {}",
                item.relative_path.to_lowercase(),
                item.line_content.to_lowercase()
            )
        })
        .collect();

    let matches = neo_frizbee::match_list_parallel(context.query, &haystack, &options, context.max_threads);
    let total_matched = matches.len();

    // Also match just the line content for bonus scoring
    let line_haystack: Vec<_> = items
        .iter()
        .map(|item| item.line_content.to_lowercase())
        .collect();

    let line_matches = neo_frizbee::match_list_parallel(
        context.query,
        &line_haystack,
        &options,
        context.max_threads,
    );

    // Create a map for quick line match lookup
    let mut line_match_map = std::collections::HashMap::new();
    for m in line_matches {
        line_match_map.insert(m.index as usize, m.score);
    }

    let mut results: Vec<_> = matches
        .into_par_iter()
        .map(|m| {
            let index = m.index as usize;
            let item = &items[index];
            let base_score = m.score as i32;

            // Bonus if the line content itself is a strong match
            let line_match_bonus = line_match_map
                .get(&index)
                .map(|&score| {
                    let line_score = score as i32;
                    // If line matches better than combined, give a bonus
                    if line_score > base_score {
                        (line_score - base_score) / 4 // 25% bonus
                    } else {
                        0
                    }
                })
                .unwrap_or(0);

            // Bonus for matches near the start of the line
            let position_bonus = if item.column < 10 {
                5
            } else if item.column < 30 {
                2
            } else {
                0
            };

            // Bonus for certain file types or important files
            let file_type_bonus = get_file_type_bonus(&item.relative_path);

            let total = base_score
                .saturating_add(line_match_bonus)
                .saturating_add(position_bonus)
                .saturating_add(file_type_bonus);

            let score = Score {
                total,
                base_score,
                filename_bonus: line_match_bonus,
                special_filename_bonus: file_type_bonus,
                frecency_boost: position_bonus,
                distance_penalty: 0,
                current_file_penalty: 0,
                exact_match: m.exact,
                match_type: "grep",
            };

            (item.clone(), score, total)
        })
        .collect();

    // Sort by score descending
    results.par_sort_unstable_by(|a, b| b.2.cmp(&a.2));

    // Take top results
    results.truncate(context.max_results);

    let (items, scores): (Vec<_>, Vec<_>) = results
        .into_iter()
        .map(|(item, score, _)| (item, score))
        .unzip();

    (items, scores, total_matched)
}

/// Give bonus points for important file types
fn get_file_type_bonus(path: &str) -> i32 {
    // Prefer source code files over config/build files
    if path.ends_with(".rs")
        || path.ends_with(".ts")
        || path.ends_with(".tsx")
        || path.ends_with(".js")
        || path.ends_with(".jsx")
        || path.ends_with(".py")
        || path.ends_with(".go")
        || path.ends_with(".java")
        || path.ends_with(".c")
        || path.ends_with(".cpp")
        || path.ends_with(".h")
    {
        5
    } else if path.contains("test") || path.contains("spec") {
        // Tests are useful but not as high priority
        2
    } else if path.ends_with(".toml")
        || path.ends_with(".json")
        || path.ends_with(".yaml")
        || path.ends_with(".yml")
    {
        // Config files are lower priority
        1
    } else {
        0
    }
}
