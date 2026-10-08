# HFT AI Research Engine

This module is a low-latency research/paper signal engine. It consumes normalized bid/ask quotes and computes microstructure features such as spread, micro-price, order-book imbalance, short-term momentum and volatility.

## Safety boundary

- No order placement is implemented here.
- `paper_only=true` is returned by the API.
- Wide spreads and low model confidence produce `WAIT`.
- Angel One credentials never enter this module.

## API

- `GET /v1/hft/status`
- `POST /v1/hft/quote`

The baseline scorer is intentionally deterministic. A trained ML model should only replace it after walk-forward validation, transaction-cost modelling, slippage analysis and paper-trading verification.
