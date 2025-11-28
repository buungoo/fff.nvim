use crate::error::Error;
use crate::grep_score::{match_and_score_grep_items, GrepScoringContext};
use crate::types::{GrepItem, GrepSearchResult};
use grep_regex::RegexMatcherBuilder;
use grep_searcher::sinks::UTF8;
use grep_searcher::SearcherBuilder;
use ignore::WalkBuilder;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use tracing::{debug, info};

pub struct ContentSearcher {
    base_path: PathBuf,
}

impl ContentSearcher {
    pub fn new(base_path: PathBuf) -> Result<Self, Error> {
        if !base_path.exists() {
            return Err(Error::InvalidPath(base_path));
        }

        Ok(Self { base_path })
    }

    /// Convert a fuzzy query into a permissive regex pattern that allows typos
    /// For example, "funk" becomes "f(u|.)n(k|.)" to match "func", "function", etc.
    fn fuzzy_query_to_regex(query: &str) -> String {
        if query.len() <= 2 {
            // For very short queries, just use the exact pattern
            return Self::escape_regex(query);
        }

        // For longer queries, make the middle characters more flexible
        let chars: Vec<char> = query.chars().collect();
        let mut pattern = String::new();

        for (i, ch) in chars.iter().enumerate() {
            if i == 0 || i == chars.len() - 1 {
                // Keep first and last character exact (but escaped)
                pattern.push_str(&Self::escape_regex(&ch.to_string()));
            } else {
                // For middle characters, allow optional substitution
                // This allows single character typos
                pattern.push_str(&format!("({}|.)", Self::escape_regex(&ch.to_string())));
            }
        }

        pattern
    }

    /// Escape special regex characters
    fn escape_regex(s: &str) -> String {
        let mut escaped = String::new();
        for ch in s.chars() {
            match ch {
                '\\' | '.' | '+' | '*' | '?' | '(' | ')' | '|' | '[' | ']' | '{' | '}' | '^' | '$' => {
                    escaped.push('\\');
                    escaped.push(ch);
                }
                _ => escaped.push(ch),
            }
        }
        escaped
    }

    /// Perform grep search in the directory
    pub fn grep_search(
        &self,
        pattern: &str,
        max_results: usize,
        max_threads: usize,
    ) -> Result<Vec<GrepItem>, Error> {
        info!("Starting grep search for pattern: {}", pattern);

        let matcher = RegexMatcherBuilder::new()
            .case_insensitive(true)
            .build(pattern)
            .map_err(|e| Error::GrepError(e.to_string()))?;

        let results = Arc::new(Mutex::new(Vec::new()));
        let max_results = Arc::new(max_results);

        WalkBuilder::new(&self.base_path)
            .threads(max_threads.max(1))
            .build_parallel()
            .run(|| {
                let matcher = matcher.clone();
                let results = Arc::clone(&results);
                let max_results = Arc::clone(&max_results);
                let base_path = self.base_path.clone();

                Box::new(move |entry| {
                    // Check if we've hit the limit
                    {
                        let current_results = results.lock().unwrap();
                        if current_results.len() >= *max_results {
                            return ignore::WalkState::Quit;
                        }
                    }

                    let entry = match entry {
                        Ok(e) => e,
                        Err(_) => return ignore::WalkState::Continue,
                    };

                    // Skip directories
                    if entry.file_type().map_or(true, |ft| ft.is_dir()) {
                        return ignore::WalkState::Continue;
                    }

                    let path = entry.path();

                    // Search in this file
                    let mut searcher = SearcherBuilder::new()
                        .line_number(true)
                        .build();

                    let mut file_results = Vec::new();

                    let search_result = searcher.search_path(
                        &matcher,
                        path,
                        UTF8(|lnum, line| {
                            let line_str = line.trim_end_matches('\n').to_string();

                            let relative_path = pathdiff::diff_paths(path, &base_path)
                                .unwrap_or_else(|| path.to_path_buf())
                                .to_string_lossy()
                                .into_owned();

                            file_results.push(GrepItem {
                                path: path.to_path_buf(),
                                relative_path: relative_path.clone(),
                                line_number: lnum as usize,
                                line_content: line_str,
                                column: 0, // We'll calculate this later if needed
                            });

                            Ok(true)
                        }),
                    );

                    if search_result.is_ok() && !file_results.is_empty() {
                        let mut results = results.lock().unwrap();
                        results.extend(file_results);
                    }

                    ignore::WalkState::Continue
                })
            });

        let final_results: Vec<GrepItem> = {
            let results_vec = match Arc::try_unwrap(results) {
                Ok(mutex) => mutex.into_inner().unwrap(),
                Err(arc) => arc.lock().unwrap().clone(),
            };
            results_vec.into_iter().take(*max_results).collect()
        };

        debug!("Grep search completed, found {} matches", final_results.len());
        Ok(final_results)
    }

    /// Perform grep search and then apply fuzzy matching on the results
    pub fn fuzzy_grep_search(
        &self,
        grep_pattern: &str,
        fuzzy_query: &str,
        max_results: usize,
        max_threads: usize,
    ) -> Result<GrepSearchResult, Error> {
        // Convert the fuzzy query into a permissive regex pattern
        let fuzzy_regex = Self::fuzzy_query_to_regex(grep_pattern);
        info!("Fuzzy regex pattern: {}", fuzzy_regex);

        // First, do the grep search with the fuzzy regex
        let grep_results = self.grep_search(&fuzzy_regex, max_results * 2, max_threads)?;

        if grep_results.is_empty() {
            return Ok(GrepSearchResult {
                items: Vec::new(),
                scores: Vec::new(),
                total_matched: 0,
                total_grepped: 0,
            });
        }

        let total_grepped = grep_results.len();

        // If no fuzzy query, return all grep results with default scores
        if fuzzy_query.is_empty() || fuzzy_query.len() < 2 {
            use crate::types::Score;
            let count = grep_results.len().min(max_results);
            let items = grep_results.into_iter().take(count).collect();
            let scores = vec![Score::default(); count];
            return Ok(GrepSearchResult {
                items,
                scores,
                total_matched: count,
                total_grepped,
            });
        }

        // Apply fuzzy matching with scoring
        let max_typos = (fuzzy_query.len() as u16 / 4).clamp(2, 6);
        let context = GrepScoringContext {
            query: fuzzy_query,
            max_results,
            max_typos,
            max_threads,
        };

        let (items, scores, total_matched) = match_and_score_grep_items(&grep_results, &context);

        Ok(GrepSearchResult {
            items,
            scores,
            total_matched,
            total_grepped,
        })
    }
}
