# Death Strike Formulas

This document summarizes how Death Strike healing is calculated in World of Warcraft, particularly for **Blood Death Knights** in modern expansions (e.g., Dragonflight).

---

## 1. Baseline (Damage vs. Health)

Death Strike’s **base** heal is whichever is higher:

$$
\text{Base DS Heal} 
= 
\max\Bigl(
  0.25 \times \text{(Damage Taken in the last 5s)},\;
  0.07 \times \text{(Max Health)}
\Bigr).
$$

- The first part is **25%** of the damage you’ve taken over the **last 5 seconds**.
- The second part is **7%** of your **maximum HP**.

---

## Common Multipliers

1. **Voracious** (Talent, +15%):

   $$
   \times 1.15
   $$

2. **Hemostasis** (+8% per stack; up to 5 stacks):

   $$
   \times \Bigl(1 + 0.08 \times \text{\# stacks}\Bigr)
   $$

   For example, if you have 3 stacks, that’s \(1 + 3 \times 0.08 = 1.24\) → **+24%**.

3. **Vampiric Blood** (+30% healing received; Improved VB adds +5% per stack):

   $$
   \times \bigl(1.3 + 0.05 \times \text{(VB stacks)}\bigr)
   $$

4. **Improved Death Strike** (+5%):

   $$
   \times 1.05
   $$

5. **Rune of Sanguination** (up to +48% based on missing HP):

   $$
   \times \Bigl(1 + 0.48 \times \text{(HP missing fraction)}\Bigr)
   $$

6. **Sanguine Ground** (+5%):

   $$
   \times 1.05
   $$


---

## 3. Versatility

After applying those healing multipliers, **Versatility** (for healing) is also multiplied in. If your Vers “damage done” is +20%, your “healing done” portion is typically **+10%**:

$$
\times \bigl(1 + \text{VersHealingPct}\bigr).
$$

For example, if your “Vers healing” is +10%, you multiply by \(1.10\).

---

## 4. Purely Additive Effects

Some bonuses add a **flat** value rather than multiplying. For example, **Dark Succor**:

- If Dark Succor is active, it adds **+10% of your max HP** to the final heal.

Thus:

$$
\text{Final DS Heal} 
= 
\bigl(\text{Multiplied DS Heal}\bigr) 
+ 
\bigl(0.10 \times \text{Max HP}\bigr).
$$

---

## 5. Putting It All Together

A **general** formula for Blood DK could look like this:

$$
\text{DS Heal} 
= 
\max\!\Bigl(
  0.25 \times \text{Damage}_{\text{5s}},\;
  0.07 \times \text{Max HP}
\Bigr)
\times 
\bigl(1 + 0.15 \times [\text{Voracious?}]\bigr)
\times 
\bigl(1 + 0.08 \times \text{HemoStacks}\bigr)
\times 
\bigl(1.3 + 0.05 \times \text{VBStacks}\bigr)
\times 
1.05 \;(\text{Improved Death Strike})
\times 
\Bigl(1 + 0.48 \times \text{MissingHPFraction}\Bigr) \;(\text{Rune of Sanguination})
\times 
1.05 \;(\text{Sanguine Ground})
\times 
\bigl(1 + \text{VersHealingPct}\bigr)
+ 
\bigl(0.10 \times \text{Max HP}\bigr)\;(\text{Dark Succor}).
$$

Where:

- \(\text{Damage}_{\text{5s}}\) = total damage taken in the last 5 seconds.
- \(\text{HemoStacks}\) is the number of **Hemostasis** stacks (0–5).
- \(\text{VBStacks}\) is the number of stacks of **Improved Vampiric Blood** (often 0 or 1).
- \(\text{MissingHPFraction}\) is \(\displaystyle 1 - \frac{\text{CurrentHP}}{\text{MaxHP}}\).
- \(\text{VersHealingPct}\) is your **Versatility**’s healing contribution (e.g., 0.10 for +10%).

> **Note**: Most of these multipliers are purely multiplicative, so the order of multiplication doesn’t matter. However, truly **additive** bonuses (like Dark Succor’s +10% of max HP) should be **added** at the end.

---

### Additional Considerations

- **Guardian Spirit**, **Ancestral Guidance**, **Divine Hymn**, etc., are additional “healing received” buffs that further multiply your DS healing if they’re up.  
- Minor **rounding** or **timing** differences can occur between addon calculations and the server’s final results.  
- **Tier set** bonuses or other gear procs can also modify Death Strike.  

That’s the **full** breakdown of how Death Strike’s core formula typically works! 
