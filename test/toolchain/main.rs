// SPDX-FileCopyrightText: 2026 AbiliSoft
// SPDX-License-Identifier: Apache-2.0

use consumer_macro::Consumer;

#[derive(Consumer)]
struct Clean;

fn main() {
    let _ = Clean;
}
