// Synthetic fixture: no proprietary Claude bundle is included in the repository.
function row(item, query) {
  const skill = item.type === "skill";
  if (!skill && item.type !== "connector-tool") return null;
  return jsx("div", {
    role: "menuitem",
    onClick: () => item.onAction(item.skillId),
    children: jsx("span", {
      className: "min-w-0 truncate",
      children: jsx(HighlightedText, {text:item.label,query:query,highlightClassName:"font-semibold"})
    })
  });
}
function Popup() { return null; }
export { Popup as SlashCommandMenuPopupBody };
