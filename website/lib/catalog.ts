// The main branch's src/economy/ contains no shop catalog or item prices.
// Do not display prices copied from an unmerged branch.
export const shopAvailability = {
  available: false,
  reason: "The current main branch does not implement an in-bot shop catalog.",
} as const;
