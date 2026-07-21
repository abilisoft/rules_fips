/*
 * SPDX-FileCopyrightText: 2026 AbiliSoft
 * SPDX-License-Identifier: Apache-2.0
 */

static float round_trip_half(float input) {
    volatile _Float16 half = (_Float16)input;
    return (float)half;
}

int main(void) {
    return round_trip_half(1.5F) == 1.5F ? 0 : 1;
}
