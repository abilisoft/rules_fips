// SPDX-FileCopyrightText: 2026 AbiliSoft
// SPDX-License-Identifier: Apache-2.0

extern crate proc_macro;

use proc_macro::TokenStream;

#[proc_macro_derive(Consumer)]
pub fn consumer(_input: TokenStream) -> TokenStream {
    TokenStream::new()
}
