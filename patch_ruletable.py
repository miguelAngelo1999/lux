"""Add up/down reorder buttons to RuleTable."""

file = r'C:\tmp\lux-client\src\components\pages\Rules\RuleTable\index.tsx'
with open(file, 'r', encoding='utf-8') as f:
    content = f.read()

# Add import for reorder SDK function and icons
content = content.replace(
    'import { AddFilled, DeleteRegular, EditRegular } from "@fluentui/react-icons";',
    'import { AddFilled, ArrowUpRegular, ArrowDownRegular, DeleteRegular, EditRegular } from "@fluentui/react-icons";'
)

content = content.replace(
    '''  addCustomizedRules,
  deleteCustomizedRules,
  editCustomizedRule,
  getRuleDetail,
  type RuleDetailItem,
} from "lux-js-sdk";''',
    '''  addCustomizedRules,
  deleteCustomizedRules,
  editCustomizedRule,
  getRuleDetail,
  reorderCustomizedRules,
  type RuleDetailItem,
} from "lux-js-sdk";'''
)

# Add handleMoveRule callback after handleAddRule
old_callback = '''  const handleAddRule = useCallback(
    async (value: RuleDetailItem) => {
      const newRule = formatRule(value);
      if (editingRule) {
        const oldRule = formatRule(editingRule);
        await editCustomizedRule(oldRule, newRule);
      } else {
        await addCustomizedRules([newRule]);
      }
      await refresh();
    },
    [editingRule, refresh],
  );'''

new_callback = old_callback + '''

  const handleMoveRule = useCallback(
    async (rule: RuleDetailItem, direction: "up" | "down") => {
      const idx = rules.indexOf(rule);
      if (direction === "up" && idx === 0) return;
      if (direction === "down" && idx === rules.length - 1) return;
      const newRules = [...rules];
      const swapIdx = direction === "up" ? idx - 1 : idx + 1;
      [newRules[idx], newRules[swapIdx]] = [newRules[swapIdx], newRules[idx]];
      await reorderCustomizedRules(newRules.map(formatRule));
      await refresh();
    },
    [rules, refresh],
  );'''

content = content.replace(old_callback, new_callback)

# Add up/down buttons to the action column
old_buttons = '''                  <div className={styles.actionBtns}>
                    <Button
                      icon={<DeleteRegular className={inlineStyles.danger} />}
                      onClick={() => handleDelete(item)}
                    />
                    <Button
                      icon={<EditRegular />}
                      onClick={() => handleEdit(item)}
                    />
                  </div>'''

new_buttons = '''                  <div className={styles.actionBtns}>
                    <Button
                      icon={<ArrowUpRegular />}
                      onClick={() => handleMoveRule(item, "up")}
                      size="small"
                      title="Move up"
                    />
                    <Button
                      icon={<ArrowDownRegular />}
                      onClick={() => handleMoveRule(item, "down")}
                      size="small"
                      title="Move down"
                    />
                    <Button
                      icon={<EditRegular />}
                      onClick={() => handleEdit(item)}
                    />
                    <Button
                      icon={<DeleteRegular className={inlineStyles.danger} />}
                      onClick={() => handleDelete(item)}
                    />
                  </div>'''

content = content.replace(old_buttons, new_buttons)

with open(file, 'w', encoding='utf-8') as f:
    f.write(content)

print("RuleTable updated with up/down buttons")
