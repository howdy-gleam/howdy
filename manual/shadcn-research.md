# shadcn/ui research for howdy-ui comparison

Checked: 2026-09-24. Sources: current official shadcn documentation, fetched live. This records the shadcn side only; absence in howdy-ui requires local source inspection.

## Scope and counting

The [current component index](https://ui.shadcn.com/docs/components) lists **64 component/documentation categories**. Count categories once, not each exported subcomponent, foundation variant, example, or block. These are not all equivalent standalone widgets: some are composition recipes or styling guidance. Do not mix the current index with legacy docs (notably Form and Sonner). Current component routes generally resolve to Base UI documentation and offer React Aria and Radix UI alternatives; foundation choice is not proof every implementation has identical APIs. The CLI explicitly supports `base`, `radix`, and `aria`. [CLI reference](https://ui.shadcn.com/docs/cli)

## Exhaustive current index

Source for this table: [official All Components index](https://ui.shadcn.com/docs/components).

| Component category | Documentation route |
|---|---|
| Accordion | https://ui.shadcn.com/docs/components/accordion |
| Alert | https://ui.shadcn.com/docs/components/alert |
| Alert Dialog | https://ui.shadcn.com/docs/components/alert-dialog |
| Aspect Ratio | https://ui.shadcn.com/docs/components/aspect-ratio |
| Attachment | https://ui.shadcn.com/docs/components/attachment |
| Avatar | https://ui.shadcn.com/docs/components/avatar |
| Badge | https://ui.shadcn.com/docs/components/badge |
| Breadcrumb | https://ui.shadcn.com/docs/components/breadcrumb |
| Bubble | https://ui.shadcn.com/docs/components/bubble |
| Button | https://ui.shadcn.com/docs/components/button |
| Button Group | https://ui.shadcn.com/docs/components/button-group |
| Calendar | https://ui.shadcn.com/docs/components/calendar |
| Card | https://ui.shadcn.com/docs/components/card |
| Carousel | https://ui.shadcn.com/docs/components/carousel |
| Chart | https://ui.shadcn.com/docs/components/chart |
| Checkbox | https://ui.shadcn.com/docs/components/checkbox |
| Collapsible | https://ui.shadcn.com/docs/components/collapsible |
| Combobox | https://ui.shadcn.com/docs/components/combobox |
| Command | https://ui.shadcn.com/docs/components/command |
| Context Menu | https://ui.shadcn.com/docs/components/context-menu |
| Data Table | https://ui.shadcn.com/docs/components/data-table |
| Date Picker | https://ui.shadcn.com/docs/components/date-picker |
| Dialog | https://ui.shadcn.com/docs/components/dialog |
| Direction | https://ui.shadcn.com/docs/components/direction |
| Drawer | https://ui.shadcn.com/docs/components/drawer |
| Dropdown Menu | https://ui.shadcn.com/docs/components/dropdown-menu |
| Empty | https://ui.shadcn.com/docs/components/empty |
| Field | https://ui.shadcn.com/docs/components/field |
| Hover Card | https://ui.shadcn.com/docs/components/hover-card |
| Input | https://ui.shadcn.com/docs/components/input |
| Input Group | https://ui.shadcn.com/docs/components/input-group |
| Input OTP | https://ui.shadcn.com/docs/components/input-otp |
| Item | https://ui.shadcn.com/docs/components/item |
| Kbd | https://ui.shadcn.com/docs/components/kbd |
| Label | https://ui.shadcn.com/docs/components/label |
| Marker | https://ui.shadcn.com/docs/components/marker |
| Menubar | https://ui.shadcn.com/docs/components/menubar |
| Message | https://ui.shadcn.com/docs/components/message |
| Message Scroller | https://ui.shadcn.com/docs/components/message-scroller |
| Native Select | https://ui.shadcn.com/docs/components/native-select |
| Navigation Menu | https://ui.shadcn.com/docs/components/navigation-menu |
| Pagination | https://ui.shadcn.com/docs/components/pagination |
| Popover | https://ui.shadcn.com/docs/components/popover |
| Progress | https://ui.shadcn.com/docs/components/progress |
| Questionnaire | https://ui.shadcn.com/docs/components/questionnaire |
| Radio Group | https://ui.shadcn.com/docs/components/radio-group |
| Resizable | https://ui.shadcn.com/docs/components/resizable |
| Scroll Area | https://ui.shadcn.com/docs/components/scroll-area |
| Select | https://ui.shadcn.com/docs/components/select |
| Separator | https://ui.shadcn.com/docs/components/separator |
| Sheet | https://ui.shadcn.com/docs/components/sheet |
| Sidebar | https://ui.shadcn.com/docs/components/sidebar |
| Skeleton | https://ui.shadcn.com/docs/components/skeleton |
| Slider | https://ui.shadcn.com/docs/components/slider |
| Spinner | https://ui.shadcn.com/docs/components/spinner |
| Switch | https://ui.shadcn.com/docs/components/switch |
| Table | https://ui.shadcn.com/docs/components/table |
| Tabs | https://ui.shadcn.com/docs/components/tabs |
| Textarea | https://ui.shadcn.com/docs/components/textarea |
| Toast | https://ui.shadcn.com/docs/components/toast |
| Toggle | https://ui.shadcn.com/docs/components/toggle |
| Toggle Group | https://ui.shadcn.com/docs/components/toggle-group |
| Tooltip | https://ui.shadcn.com/docs/components/tooltip |
| Typography | https://ui.shadcn.com/docs/components/typography |

## Interpretation of recent categories

- Attachment covers file/image display, metadata, upload status and actions; it is not an upload backend. [Attachment](https://ui.shadcn.com/docs/components/base/attachment)
- Bubble supplies the conversation surface, grouping and reactions. Message adds the surrounding avatar, alignment, header and footer. [Bubble](https://ui.shadcn.com/docs/components/base/bubble), [Message](https://ui.shadcn.com/docs/components/base/message)
- Marker supplies status rows, system notes and labeled conversation separators. [Marker](https://ui.shadcn.com/docs/components/base/marker)
- Message Scroller addresses streamed conversation following, transcript positioning, history loading and message navigation. [Message Scroller](https://ui.shadcn.com/docs/components/base/message-scroller)
- Questionnaire supplies a multistep flow supporting single/multiple choice, freeform and optional questions. [Questionnaire](https://ui.shadcn.com/docs/components/base/questionnaire)
- Current Toast docs install `toast`, expose status variants, actions and promise lifecycle updates. Do not describe current Toast as deprecated based on older shadcn docs. [Toast](https://ui.shadcn.com/docs/components/base/toast)

## Tooling, distribution and ecosystem capabilities

| Capability | Verified scope and comparison caveat | Source |
|---|---|---|
| Editable source distribution | Component source is copied into the consumer project and composed/customized there; this differs architecturally from consuming a versioned component package. It is a choice, not inherently a missing feature. | [Introduction](https://ui.shadcn.com/docs) |
| CLI setup and installation | Initializes configuration/dependencies/CSS variables; installs components plus dependencies; supports source URLs/local paths, inspection, dry-run and file diff preview. | [CLI](https://ui.shadcn.com/docs/cli) |
| CLI maintenance | Preset application/inspection, registry search/view/build, docs fetching, project info, and migrations for icons, colors, RTL and other changes. | [CLI](https://ui.shadcn.com/docs/cli) |
| Framework setup and foundation choice | CLI lists Next, Vite, TanStack Start, React Router, Laravel and Astro templates; supports Base UI, Radix UI and React Aria foundations. This does not mean the shipped React components work in arbitrary non-React frontends. | [CLI](https://ui.shadcn.com/docs/cli) |
| Monorepo installation | Resolves workspace destinations, dependencies and imports; can scaffold web/ui workspaces. Mere existence of a monorepo in howdy is not equivalent to this installation feature. | [Monorepo](https://ui.shadcn.com/docs/monorepo) |
| Registry infrastructure | Custom registries distribute components, hooks, pages, config and other files; registry transport is framework-agnostic. Documentation includes GitHub registries, namespaces and authentication. | [Registry](https://ui.shadcn.com/docs/registry) |
| AI tooling | MCP supports discovering, searching and installing registry entries. Separately, an agent skill reads project configuration to guide composition/customization. | [MCP](https://ui.shadcn.com/docs/mcp), [Skills](https://ui.shadcn.com/docs/skills) |
| Theme tokens and theme creation | Semantic CSS variables cover surfaces, text, interaction, charts, sidebar and radius, with dark overrides. The visual Create tool previews colors, fonts, radius and icons and exports a preset. | [Theming](https://ui.shadcn.com/docs/theming) |
| Typography system | Typeset is an editable CSS system for HTML/rendered Markdown with context-specific preset classes. Count current Typography index entry once; do not invent a second primitive count for Typeset. | [Typeset](https://ui.shadcn.com/docs/typeset) |
| Application blocks | Ready-to-copy dashboard, sidebar, login and signup compositions; dashboard example includes chart and data table. Blocks are a separate productivity layer, not additional primitive categories. | [Blocks](https://ui.shadcn.com/blocks) |
| Form recipes | Official React Hook Form guide combines Field, controlled inputs, Zod validation, error handling and accessibility guidance. The documentation navigation also lists TanStack Form and Formisch guides. | [React Hook Form](https://ui.shadcn.com/docs/forms/react-hook-form), [Docs navigation](https://ui.shadcn.com/docs/components) |
| Design ecosystem | Official docs list free/paid Figma resources but explicitly identify them as community-maintained. Do not label them an official first-party Figma kit. | [Figma](https://ui.shadcn.com/docs/figma) |

## Limits

This is a dated inventory of the public current index and verified major ecosystem capabilities, not an exhaustive API-by-API audit of all subcomponent props or every community registry. Published accessibility claims and documented primitives are not substitutes for an independent accessibility audit. Report local gaps as missing implementations, missing reusable abstractions or missing documentation as appropriate; avoid treating a differently named local equivalent as absent.
