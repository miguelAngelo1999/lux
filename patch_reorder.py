"""Add rule reordering to backend, SDK, and UI."""

# === 1. Add ReorderCustomizedRules to configuration/rule.go ===
with open(r'C:\tmp\itun2socks\internal\configuration\rule.go', 'r', encoding='utf-8') as f:
    content = f.read()

if 'ReorderCustomizedRules' not in content:
    # Add after EditCustomizedRule function
    addition = '''
// ReorderCustomizedRules replaces the entire customized rules list with a new ordered list.
func ReorderCustomizedRules(rules []string) error {
\tc, err := Read()
\tif err != nil {
\t\treturn err
\t}
\t// Validate each rule exists and format it
\tnewRules := make([]string, 0, len(rules))
\tfor _, rule := range rules {
\t\tformattedRule := strings.TrimSpace(rule)
\t\tif formattedRule != "" {
\t\t\tnewRules = append(newRules, formattedRule)
\t\t}
\t}
\tc.Rules = newRules
\treturn Write(c)
}
'''
    content += addition
    with open(r'C:\tmp\itun2socks\internal\configuration\rule.go', 'w', encoding='utf-8') as f:
        f.write(content)
    print("1. Added ReorderCustomizedRules to configuration/rule.go")
else:
    print("1. ReorderCustomizedRules already exists")

# === 2. Add endpoint to routes/rule.go ===
with open(r'C:\tmp\itun2socks\api\routes\rule.go', 'r', encoding='utf-8') as f:
    content = f.read()

if 'reorderCustomizedRules' not in content:
    # Add route
    content = content.replace(
        'r.Put("/customized", editCustomizedRule)',
        'r.Put("/customized", editCustomizedRule)\n\tr.Post("/customized/reorder", reorderCustomizedRules)'
    )
    # Add handler
    content += '''
func reorderCustomizedRules(w http.ResponseWriter, r *http.Request) {
\tvar req map[string][]string
\tif err := render.DecodeJSON(r.Body, &req); err != nil {
\t\trender.Status(r, http.StatusBadRequest)
\t\trender.JSON(w, r, ErrBadRequest)
\t\treturn
\t}
\tif err := configuration.ReorderCustomizedRules(req["rules"]); err != nil {
\t\trender.Status(r, http.StatusInternalServerError)
\t\trender.JSON(w, r, NewError(err.Error()))
\t\treturn
\t}
\tif manager.GetIsStarted() {
\t\texecutor.UpdateRule()
\t}
\trender.NoContent(w, r)
}
'''
    with open(r'C:\tmp\itun2socks\api\routes\rule.go', 'w', encoding='utf-8') as f:
        f.write(content)
    print("2. Added reorderCustomizedRules endpoint")
else:
    print("2. Endpoint already exists")

# === 3. Add SDK function ===
with open(r'C:\tmp\lux-client\modules\lux-js-sdk\rule.ts', 'r', encoding='utf-8') as f:
    content = f.read()

if 'reorderCustomizedRules' not in content:
    content += '''
export const reorderCustomizedRules = async (rules: string[]): Promise<void> => {
  const url = `${urtConfig.rule}/customized/reorder`;
  await axios.post(url, { rules });
};
'''
    with open(r'C:\tmp\lux-client\modules\lux-js-sdk\rule.ts', 'w', encoding='utf-8') as f:
        f.write(content)
    print("3. Added SDK function")
else:
    print("3. SDK function already exists")

# === 4. Export from SDK index ===
with open(r'C:\tmp\lux-client\modules\lux-js-sdk\index.ts', 'r', encoding='utf-8') as f:
    content = f.read()

if 'reorderCustomizedRules' not in content:
    content += '\nexport { reorderCustomizedRules } from "./rule";\n'
    with open(r'C:\tmp\lux-client\modules\lux-js-sdk\index.ts', 'w', encoding='utf-8') as f:
        f.write(content)
    print("4. Added to SDK index")
else:
    print("4. Already exported")

print("\nDone! Now update RuleTable.tsx to add up/down buttons.")
