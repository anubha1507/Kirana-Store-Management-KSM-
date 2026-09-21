# Kirana Store Management Software — Design System & Project Architecture

**Version:** 1.0  
**Product:** Kirana Store Management Software  
**Design direction:** Minimal, calm, practical, modern, and easy for non-technical shop owners.

---

## 1. Design Vision

The application should feel as simple as ChatGPT: generous spacing, restrained colors, clear typography, subtle borders, and minimal visual noise.

The product has two distinct experiences:

1. **Landing page:** Slightly expressive and premium, using tasteful 3D visuals to communicate modern retail management.
2. **Application dashboard:** Highly functional and minimalist, with a persistent sidebar, clean data surfaces, and fast workflows.

The design should prioritize clarity over decoration.

### Core principles

- Minimal cognitive load.
- One primary action per screen.
- Clear hierarchy and predictable navigation.
- White mode and dark mode with equivalent usability.
- Avoid excessive gradients, shadows, rounded cards, and colorful charts.
- Use motion only when it improves feedback or orientation.
- Design for desktop first, but remain responsive on tablets and mobile.

---

# 2. Product Experience Architecture

## Primary user roles

### Owner

Full access to products, purchases, billing, customers, reports, settings, and users.

### Cashier

Access to billing, sales history, and limited product lookup.

### Manager

Access to inventory, purchases, billing, reports, and customers.

Role permissions should be enforced by the backend, not only hidden in the frontend.

---

# 3. Application Information Architecture

```text
Authentication
├── Login
├── Forgot Password
└── Reset Password

Main Application
├── Dashboard
├── Billing / POS
├── Products
│   ├── All Products
│   ├── Add Product
│   ├── Categories
│   └── Stock Alerts
├── Purchases
│   ├── Purchase History
│   └── Add Purchase
├── Sales
│   ├── Sales History
│   └── Sale Details
├── Customers
│   ├── Customer List
│   ├── Customer Details
│   └── Udhaar / Credit
├── Reports
│   ├── Sales Reports
│   ├── Inventory Reports
│   └── Profit & Loss
└── Settings
    ├── Store Profile
    ├── Users & Roles
    ├── Tax Settings
    └── Preferences
```

---

# 4. Global Layout System

## Desktop application shell

```text
┌──────────────────────────────────────────────────────────────────────┐
│ Sidebar                  │ Top Bar                                  │
│                          ├───────────────────────────────────────────┤
│ Logo / Store Name        │ Breadcrumb / Page Title      User Menu    │
│                          ├───────────────────────────────────────────┤
│ Dashboard                │                                           │
│ Billing                  │                                           │
│ Products                 │              Main Content                 │
│ Purchases                │                                           │
│ Sales                    │                                           │
│ Customers                │                                           │
│ Reports                  │                                           │
│                          │                                           │
│ Settings                 │                                           │
│                          │                                           │
│ Theme Toggle             │                                           │
│ User Profile             │                                           │
└──────────────────────────┴───────────────────────────────────────────┘
```

## Sidebar

- Width: 248px expanded.
- Width: 72px collapsed.
- Fixed on desktop.
- Scrollable independently if needed.
- Active item uses a subtle background and high-contrast text.
- Icons are supporting elements, never the only label.

### Sidebar options

| Icon | Label | Purpose |
|---|---|---|
| Layout Dashboard | Dashboard | Business overview |
| Receipt | Billing | Create a new bill |
| Package | Products | Product and stock management |
| Truck | Purchases | Purchase stock from suppliers |
| Chart Line | Sales | Transaction history |
| Users | Customers | Customer and credit management |
| Bar Chart | Reports | Business analytics |
| Settings | Settings | Store configuration |

Use a consistent icon library such as Lucide Icons.

---

# 5. Responsive Breakpoints

```text
Mobile:   0–639px
Tablet:   640–1023px
Desktop:  1024–1279px
Wide:     1280px+
```

### Behavior

- Desktop: persistent sidebar.
- Tablet: collapsible sidebar.
- Mobile: sidebar becomes a drawer or bottom navigation for primary actions.
- Billing should remain usable on small screens with a stacked cart layout.

---

# 6. Theme System

The application supports exactly two themes:

1. Light mode.
2. Dark mode.

The visual language should remain the same in both themes.

Do not create separate brand identities for dark and light mode.

## Theme philosophy

Light mode should feel clean, paper-like, and professional.

Dark mode should feel similar to ChatGPT's dark interface: charcoal surfaces, soft borders, and off-white text rather than pure black and pure white.

---

# 7. Color Palette

## Brand palette

The brand should be neutral-first, with one restrained accent color.

### Primary Accent: Indigo

Used for primary actions, active states, links, and focus indicators.

| Token | Hex | Usage |
|---|---|---|
| Brand 50 | #EEF2FF | Very light accent backgrounds |
| Brand 100 | #E0E7FF | Hover backgrounds |
| Brand 500 | #6366F1 | Primary interactive accent |
| Brand 600 | #4F46E5 | Hover / stronger action |
| Brand 700 | #4338CA | Active or pressed state |

Avoid using accent color for large surfaces.

---

## Light Theme Tokens

| Token | Hex | Purpose |
|---|---|---|
| Background | #FFFFFF | Main application background |
| Surface | #FFFFFF | Cards and panels |
| Surface Secondary | #F7F7F8 | Sidebar, secondary regions |
| Surface Tertiary | #F0F0F1 | Hover and subtle grouping |
| Border | #E5E5E7 | Default borders |
| Border Strong | #D4D4D8 | Input and emphasized borders |
| Text Primary | #18181B | Headings and primary content |
| Text Secondary | #52525B | Descriptions and metadata |
| Text Muted | #71717A | Supporting information |
| Text Disabled | #A1A1AA | Disabled controls |

---

## Dark Theme Tokens

| Token | Hex | Purpose |
|---|---|---|
| Background | #18181B | Main application background |
| Surface | #202023 | Cards and panels |
| Surface Secondary | #242427 | Sidebar and secondary regions |
| Surface Tertiary | #2C2C30 | Hover and selected surfaces |
| Border | #35353A | Default borders |
| Border Strong | #45454B | Emphasized borders |
| Text Primary | #F4F4F5 | Main content |
| Text Secondary | #A1A1AA | Secondary content |
| Text Muted | #71717A | Metadata |
| Text Disabled | #52525B | Disabled controls |

---

## Semantic Colors

Use semantic colors sparingly.

| Meaning | Light | Dark | Usage |
|---|---|---|---|
| Success | #16A34A | #4ADE80 | Completed payments, healthy stock |
| Warning | #D97706 | #FBBF24 | Low stock, pending actions |
| Danger | #DC2626 | #F87171 | Errors, destructive actions |
| Info | #2563EB | #60A5FA | Informational messages |

Semantic colors should appear in text, icons, badges, or small indicators—not dominate entire screens.

---

# 8. Typography System

Use a modern sans-serif typeface with excellent readability.

## Recommended font

**Inter** is the primary choice.

Fallback stack:

```css
font-family: Inter, ui-sans-serif, system-ui, -apple-system,
  BlinkMacSystemFont, "Segoe UI", sans-serif;
```

## Type scale

| Style | Size | Weight | Line Height | Usage |
|---|---:|---:|---:|---|
| Display | 48px | 600 | 1.1 | Landing page hero |
| H1 | 32px | 600 | 1.2 | Main page title |
| H2 | 24px | 600 | 1.3 | Section headings |
| H3 | 18px | 600 | 1.4 | Card headings |
| Body Large | 16px | 400 | 1.5 | Important descriptions |
| Body | 14px | 400 | 1.5 | Standard UI text |
| Label | 13px | 500 | 1.4 | Form labels |
| Caption | 12px | 400 | 1.4 | Metadata and hints |
| Metric | 28px | 600 | 1.1 | Dashboard numbers |

### Typography rules

- Avoid all-caps headings.
- Use sentence case for buttons and navigation.
- Do not use more than two font weights in one component.
- Keep body text at least 14px on desktop.
- Use tabular numerals for financial values where supported.

---

# 9. Spacing System

Use a 4px base spacing scale.

| Token | Value |
|---|---:|
| space-1 | 4px |
| space-2 | 8px |
| space-3 | 12px |
| space-4 | 16px |
| space-5 | 20px |
| space-6 | 24px |
| space-8 | 32px |
| space-10 | 40px |
| space-12 | 48px |
| space-16 | 64px |
| space-20 | 80px |

Recommended default:

- Page padding: 32px desktop.
- Card padding: 20–24px.
- Form field gap: 16px.
- Section gap: 32px.
- Table row height: 56px minimum.

---

# 10. Border Radius and Elevation

Keep surfaces restrained.

| Component | Radius |
|---|---:|
| Small controls | 6px |
| Inputs | 8px |
| Buttons | 8px |
| Cards | 12px |
| Large panels | 16px |
| Modal | 16px |
| Landing page visual containers | 20px |

## Shadows

Use shadows only when necessary.

Light mode:

```css
box-shadow: 0 1px 3px rgba(0, 0, 0, 0.04);
```

Dark mode should generally rely on borders and contrast instead of shadows.

Avoid floating every card. Flat surfaces are preferred.

---

# 11. Component Design System

## Buttons

### Primary

- Indigo background.
- White text.
- 8px radius.
- Height: 40px standard.
- Height: 44px large.

### Secondary

- Transparent or surface background.
- Subtle border.
- Primary text color.

### Ghost

- No border.
- Transparent background.
- Hover surface only.

### Destructive

- Neutral by default when possible.
- Red only for confirmation or destructive actions.

Example labels:

- Add product
- Create bill
- Save changes
- Record payment
- Export report

Avoid vague labels such as "Submit" or "Click here."

---

## Inputs

- Height: 40–44px.
- Border: 1px solid border token.
- Radius: 8px.
- Clear labels above fields.
- Visible focus ring using brand color.
- Helpful placeholder text, but never rely on placeholders as labels.

---

## Cards

Cards should group related information, not decorate the page.

Recommended card structure:

```text
Card
├── Header
│   ├── Title
│   └── Optional action
├── Content
└── Optional footer / metadata
```

Use cards for:

- Sales metrics.
- Low stock summary.
- Recent transactions.
- Quick actions.

Do not put every table inside a card if the surrounding page already provides enough separation.

---

# 12. Dashboard Page Design

The dashboard is the primary operational screen.

## Dashboard goals

Within five seconds, the shop owner should understand:

- Today's sales.
- Number of bills.
- Current inventory alerts.
- Outstanding credit.
- Important recent activity.

## Dashboard wireframe

```text
┌───────────────────────────────────────────────────────────────────┐
│ Dashboard                                      13 Sep 2026        │
│ Good morning. Here's your store overview.                         │
├───────────────────────────────────────────────────────────────────┤
│                                                                   │
│ ┌──────────────┐ ┌──────────────┐ ┌──────────────┐ ┌────────────┐ │
│ │ Today's Sales│ │ Total Bills  │ │ Low Stock    │ │ Udhaar Due │ │
│ │ ₹12,450      │ │ 45           │ │ 15 products  │ │ ₹8,200     │ │
│ └──────────────┘ └──────────────┘ └──────────────┘ └────────────┘ │
│                                                                   │
│ ┌─────────────────────────────────────┐ ┌────────────────────────┐│
│ │ Sales Overview                      │ │ Quick Actions          ││
│ │                                     │ │                        ││
│ │ Simple line/bar chart               │ │ + Create bill          ││
│ │                                     │ │ + Add product          ││
│ │                                     │ │ + Record purchase      ││
│ └─────────────────────────────────────┘ └────────────────────────┘│
│                                                                   │
│ ┌─────────────────────────────────────┐ ┌────────────────────────┐│
│ │ Recent Transactions                 │ │ Low Stock Alerts        ││
│ │ Invoice | Customer | Amount | Time  │ │ Product | Remaining     ││
│ └─────────────────────────────────────┘ └────────────────────────┘│
└───────────────────────────────────────────────────────────────────┘
```

### Dashboard design rules

- Maximum 4 summary metric cards in the first row.
- Use one primary chart only.
- Avoid dashboard overload.
- Make "Create bill" the most visible quick action.
- Show empty states when there is no data.
- Use skeleton loaders during data fetching.

---

# 13. Billing / POS Design

Billing is the most frequently used workflow and should be optimized for speed.

## Layout

```text
┌────────────────────────────────────────────────────────────────────┐
│ Billing                                                            │
├──────────────────────────────────────────┬─────────────────────────┤
│ Product Search                           │ Current Bill            │
│ [ Search products... ]                   │                         │
│                                          │ Rice x2       ₹700      │
│ Category filters                         │ Maggi x3      ₹45       │
│ [All] [Grocery] [Snacks]                 │ Salt x1       ₹28       │
│                                          │                         │
│ Product Grid / List                      │ Subtotal      ₹773      │
│ ┌────────────┐ ┌────────────┐            │ Discount      ₹0        │
│ │ Rice       │ │ Maggi      │            │ Total         ₹773      │
│ │ ₹350       │ │ ₹15        │            │                         │
│ └────────────┘ └────────────┘            │ [Cash] [UPI] [Credit]  │
│                                          │                         │
│                                          │ [Generate Bill]         │
└──────────────────────────────────────────┴─────────────────────────┘
```

## Billing requirements

- Search by name, SKU, or barcode.
- Keyboard-friendly navigation.
- Quantity editing.
- Automatic subtotal and total.
- Payment method selection.
- Optional customer selection.
- Confirmation before completing credit transactions.
- Stock validation before sale completion.
- Prevent negative stock unless explicitly allowed by store settings.

---

# 14. Product Management Design

## Product list

Columns:

- Product name.
- Category.
- Selling price.
- Cost price.
- Stock quantity.
- Unit.
- Stock status.
- Actions.

Use status badges:

- In stock.
- Low stock.
- Out of stock.

## Add Product form

Fields:

- Product name.
- Category.
- SKU/barcode (optional).
- Selling price.
- Cost price.
- Opening stock.
- Unit.
- Low-stock threshold.

Use a two-column form on desktop and one column on mobile.

---

# 15. Inventory and Purchase Design

Inventory should distinguish between stock movement types.

```text
Stock Movement
├── Purchase
├── Sale
├── Sale Return
├── Purchase Return
├── Damage / Expiry
└── Manual Adjustment
```

Every adjustment should store:

- Product ID.
- Quantity change.
- Movement type.
- Reference transaction.
- User.
- Timestamp.
- Optional note.

This provides traceability and prevents unexplained stock differences.

---

# 16. Sales and Reports Design

## Sales History

Filters:

- Date range.
- Payment method.
- Customer.
- User/cashier.

Table actions:

- View invoice.
- Print invoice.
- Download invoice.
- Refund/return where permitted.

## Reports

Start with practical reports:

1. Daily sales.
2. Monthly sales.
3. Product-wise sales.
4. Payment method summary.
5. Low-stock report.
6. Gross profit estimate.

Charts should be simple and readable.

Preferred chart style:

- Thin lines.
- Minimal grid lines.
- Neutral axes.
- One accent color.
- Tooltips on hover.
- Accessible labels and tables beneath charts.

---

# 17. Customer and Udhaar Design

Customer pages should make outstanding balances immediately understandable.

## Customer list columns

- Name.
- Phone.
- Total purchases.
- Outstanding credit.
- Last transaction.

## Customer detail

```text
Customer: Rahul Sharma
Phone: +91 XXXXX XXXXX

Outstanding Balance: ₹1,000

Transaction History
Date       Description       Amount     Status
13 Sep     Grocery purchase  ₹500       Credit
10 Sep     Payment received  ₹300       Paid
```

Primary actions:

- Record payment.
- Create bill.
- View transaction history.

Never expose unnecessary personal information in shared screens.

---

# 18. Landing Page Design

The landing page can be more expressive than the dashboard while remaining professional.

## Visual direction

- Minimal dark or light hero section.
- One tasteful 3D illustration of a modern kirana store, receipt, inventory boxes, or floating product shelves.
- Soft ambient lighting.
- Subtle depth and shadows.
- No excessive neon or gaming-style gradients.

The 3D visual should support the product message rather than distract from it.

## Landing page structure

```text
Navbar
├── Logo
├── Features
├── How it works
├── Pricing (future)
└── Login / Get started

Hero
├── Small eyebrow: Simple store management
├── Main headline
├── Supporting paragraph
├── Primary CTA: Get started
├── Secondary CTA: See how it works
└── 3D visual

Trust / benefit strip
├── Inventory
├── Billing
├── Sales insights

Feature sections
├── Inventory made simple
├── Faster billing
├── Clear business insights

Workflow section
├── Add products
├── Sell products
├── Track sales

Final CTA

Footer
```

## Suggested hero copy

**Run your kirana store with clarity.**

Manage products, billing, inventory, and sales from one simple workspace.

Primary CTA: **Get started**

Secondary CTA: **Explore features**

---

# 19. 3D Landing Page Guidelines

Use a lightweight 3D asset or rendered illustration.

### Recommended subject

A stylized floating kirana store shelf containing:

- Rice bags.
- Grocery packets.
- Receipt.
- Small barcode label.
- Floating dashboard card.

### Style

- Low-poly or smooth clay-like 3D.
- Soft neutral materials.
- Limited color accents.
- Transparent or subtle background.
- No photorealistic clutter.

### Performance

- Prefer optimized GLB/GLTF assets.
- Lazy-load below-the-fold 3D.
- Provide a static fallback image.
- Respect reduced-motion preferences.
- Do not make 3D required for understanding the page.

---

# 20. Motion and Interaction

Motion should be subtle and functional.

## Recommended transitions

```css
transition: background-color 160ms ease,
            border-color 160ms ease,
            color 160ms ease,
            transform 160ms ease;
```

Use animation for:

- Sidebar open/close.
- Modal entrance.
- Toast notifications.
- Loading skeletons.
- Button feedback.
- Landing page 3D movement.

Avoid:

- Constant floating animations.
- Excessive page transitions.
- Bouncy dashboard cards.
- Auto-playing distracting effects.

Support:

```css
@media (prefers-reduced-motion: reduce) {
  * {
    animation-duration: 0.01ms !important;
    transition-duration: 0.01ms !important;
  }
}
```

---

# 21. Accessibility Requirements

The application should target WCAG 2.2 AA principles.

Requirements:

- Keyboard navigation for all major actions.
- Visible focus states.
- Color is never the only status indicator.
- Minimum readable text sizes.
- Sufficient contrast in both themes.
- Semantic HTML.
- Labels for all form fields.
- Accessible error messages.
- Screen-reader-friendly tables and dialogs.
- Touch targets of approximately 44px where practical.

---

# 22. Technical Project Architecture

Recommended stack:

| Layer | Technology |
|---|---|
| Frontend | React + TypeScript |
| Build Tool | Vite |
| Styling | Tailwind CSS |
| Components | shadcn/ui + Radix primitives |
| Icons | Lucide React |
| Backend | FastAPI + Python |
| API Validation | Pydantic |
| Database | PostgreSQL |
| ORM | SQLAlchemy |
| Authentication | JWT + refresh tokens |
| State Management | TanStack Query + Zustand |
| Charts | Recharts |
| Forms | React Hook Form + Zod |
| File Storage | S3-compatible storage |
| Deployment | Docker |

This stack keeps the interface fast, accessible, and maintainable.

---

# 23. Frontend Folder Structure

```text
frontend/
├── src/
│   ├── app/
│   │   ├── routes/
│   │   ├── providers/
│   │   └── app.tsx
│   ├── assets/
│   ├── components/
│   │   ├── ui/
│   │   ├── layout/
│   │   ├── forms/
│   │   ├── tables/
│   │   └── feedback/
│   ├── features/
│   │   ├── auth/
│   │   ├── dashboard/
│   │   ├── billing/
│   │   ├── products/
│   │   ├── purchases/
│   │   ├── sales/
│   │   ├── customers/
│   │   ├── reports/
│   │   └── settings/
│   ├── hooks/
│   ├── lib/
│   ├── services/
│   ├── stores/
│   ├── types/
│   ├── utils/
│   └── styles/
│       ├── globals.css
│       └── tokens.css
├── public/
├── package.json
└── vite.config.ts
```

### Feature-based organization

Each feature should own its:

- Components.
- API calls.
- Hooks.
- Types.
- Validation schemas.
- Tests.

This prevents the project from becoming a large collection of unrelated components.

---

# 24. Backend Folder Structure

```text
backend/
├── app/
│   ├── main.py
│   ├── config.py
│   ├── database.py
│   ├── dependencies.py
│   ├── models/
│   │   ├── user.py
│   │   ├── product.py
│   │   ├── sale.py
│   │   ├── sale_item.py
│   │   ├── purchase.py
│   │   ├── customer.py
│   │   └── stock_movement.py
│   ├── schemas/
│   ├── api/
│   │   └── v1/
│   │       ├── auth.py
│   │       ├── products.py
│   │       ├── billing.py
│   │       ├── purchases.py
│   │       ├── sales.py
│   │       ├── customers.py
│   │       └── reports.py
│   ├── services/
│   │   ├── billing_service.py
│   │   ├── inventory_service.py
│   │   ├── reporting_service.py
│   │   └── credit_service.py
│   ├── repositories/
│   ├── core/
│   └── tests/
├── alembic/
├── requirements.txt
└── Dockerfile
```

---

# 25. Database Architecture

Use PostgreSQL with normalized relational tables.

```text
users
stores
categories
products
suppliers
purchases
purchase_items
sales
sale_items
customers
payments
stock_movements
audit_logs
```

## Core relationships

```text
Store
├── Users
├── Products
├── Customers
├── Suppliers
├── Purchases
└── Sales

Sale
└── Sale Items
    └── Product

Purchase
└── Purchase Items
    └── Product

Customer
└── Payments / Credit Transactions
```

Every business record should include `store_id` if multi-store support is planned later.

---

# 26. API Design Principles

Use RESTful APIs with predictable naming.

Examples:

```text
POST   /api/v1/auth/login
GET    /api/v1/products
POST   /api/v1/products
GET    /api/v1/products/{id}
PATCH  /api/v1/products/{id}
DELETE /api/v1/products/{id}

POST   /api/v1/sales
GET    /api/v1/sales
GET    /api/v1/sales/{id}

POST   /api/v1/purchases
GET    /api/v1/purchases

GET    /api/v1/reports/sales
GET    /api/v1/reports/inventory
```

## Important backend rules

- Validate all financial values server-side.
- Use database transactions when creating a sale.
- Lock or safely update stock during checkout.
- Never trust frontend totals.
- Store the price at the time of sale in `sale_items`.
- Record audit logs for sensitive actions.

---

# 27. Data and Business Rules

## Product pricing

A product should have:

- Cost price.
- Selling price.
- Optional tax rate.

Historical sales must retain the price used at checkout.

## Inventory

Stock cannot silently become negative.

Every stock change should create a stock movement record.

## Billing

A sale should only be marked completed when:

1. Products exist.
2. Quantities are valid.
3. Stock is sufficient.
4. Totals are recalculated server-side.
5. Payment method is valid.
6. Transaction is committed successfully.

## Credit

Credit sales should create a customer ledger entry.

Payments should reduce the outstanding balance.

---

# 28. Security Architecture

Minimum requirements:

- Password hashing with Argon2 or bcrypt.
- Short-lived access tokens.
- Refresh token rotation.
- Role-based authorization.
- Rate limiting on authentication endpoints.
- Input validation.
- SQL injection protection through ORM.
- HTTPS in production.
- Secure HTTP-only cookies where applicable.
- Audit logs for billing and inventory changes.

Do not store plain-text passwords.

---

# 29. Design Tokens Implementation Example

```css
:root {
  --background: 0 0% 100%;
  --surface: 0 0% 100%;
  --surface-secondary: 240 5% 97%;
  --border: 240 5% 91%;
  --text-primary: 240 6% 10%;
  --text-secondary: 240 4% 32%;
  --text-muted: 240 4% 46%;
  --brand: 239 84% 67%;
  --brand-foreground: 0 0% 100%;
}

.dark {
  --background: 240 6% 10%;
  --surface: 240 5% 13%;
  --surface-secondary: 240 5% 15%;
  --border: 240 5% 22%;
  --text-primary: 240 5% 96%;
  --text-secondary: 240 5% 65%;
  --text-muted: 240 4% 46%;
  --brand: 239 84% 67%;
  --brand-foreground: 0 0% 100%;
}
```

Use semantic tokens throughout the application instead of hardcoding colors inside components.

---

# 30. Design Quality Checklist

Before shipping any screen, verify:

### Visual

- Is the primary action obvious?
- Is there enough whitespace?
- Are borders and shadows subtle?
- Is the color palette restrained?
- Does the dark theme preserve hierarchy?

### Usability

- Can a new user understand the page without training?
- Are errors clear and actionable?
- Are loading and empty states included?
- Can common tasks be completed with minimal clicks?

### Accessibility

- Is keyboard navigation possible?
- Are focus states visible?
- Is text contrast sufficient?
- Are status colors supported by text or icons?

### Performance

- Are unnecessary animations avoided?
- Are large assets optimized?
- Is 3D lazy-loaded?
- Are tables paginated for large datasets?

---

# 31. Recommended Design Personality

The final product should feel:

**Calm · Reliable · Modern · Practical · Focused**

Avoid making it feel:

**Overly colorful · Gamified · Corporate-heavy · Complicated · Decorative**

The ideal reference is a combination of:

- ChatGPT-style application simplicity.
- Linear-style information hierarchy.
- Modern POS software efficiency.
- Subtle premium landing-page presentation.

---

# 32. Final Product Design Summary

The Kirana Store Management Software should use a neutral, minimalist design system with:

- Light and dark themes only.
- White/light-gray surfaces in light mode.
- Charcoal surfaces in dark mode.
- Indigo as the restrained primary accent.
- Inter typography.
- Lucide icons.
- 4px spacing scale.
- 8–16px component radius.
- Subtle borders instead of heavy shadows.
- Persistent sidebar dashboard navigation.
- Fast, focused billing workflow.
- Expressive but lightweight 3D landing page.
- Accessible and responsive components.
- Feature-based frontend architecture.
- Modular FastAPI backend.
- PostgreSQL relational database.

The design goal is simple: **make running a kirana store feel as easy as using a modern productivity application.**
