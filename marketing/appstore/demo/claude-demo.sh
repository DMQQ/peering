#!/bin/bash
clear
printf '\n \033[38;5;208m✻\033[0m \033[1mClaude Code\033[0m  v2.1\n\n'
printf ' \033[2m> add rate limiting to the orders API\033[0m\n\n'
printf ' \033[38;5;208m●\033[0m I will add a limiter to routes/orders.ts and a test.\n\n'
printf ' \033[38;5;208m●\033[0m \033[1mEdit\033[0m(src/routes/orders.ts)\n'
printf '   \033[32m+ import { limiter } from "../middleware/limit";\033[0m\n'
printf '   \033[32m+ orders.use(limiter({ max: 60 }));\033[0m\n\n'
printf ' ┌──────────────────────────────────────────┐\n'
printf ' │ Run \033[1mnpm test\033[0m?                           │\n'
printf ' │ \033[1m❯ 1. Yes\033[0m                                │\n'
printf ' │   2. Yes, and do not ask again           │\n'
printf ' │   3. No, tell Claude what to do instead  │\n'
printf ' └──────────────────────────────────────────┘\n'
