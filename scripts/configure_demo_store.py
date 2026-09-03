# Configure the Odoo demo ecommerce store (run via `odoo-bin shell`).
# Enables a shop currency switcher for SAR, AED, and USD.
from odoo import fields
from odoo.exceptions import UserError

Company = env['res.company']
Currency = env['res.currency']
CurrencyRate = env['res.currency.rate']
Country = env['res.country']
ProductTemplate = env['product.template']
Pricelist = env['product.pricelist']
Website = env['website']
Settings = env['res.config.settings']

company = Company.browse(env.company.id)
sa = Country.search([('code', '=', 'SA')], limit=1)
if not sa:
    raise Exception('SA country is missing from the database.')

# Approx demo FX vs SAR (hardcoded; not live market rates).
# Technical Odoo rate = units of this currency per 1 company currency.
#   1 SAR ≈ 0.98 AED  → 1 AED ≈ 1.02 SAR
#   1 SAR ≈ 0.2667 USD → 1 USD ≈ 3.75 SAR
DEMO_RATES_PER_SAR = {
    'SAR': 1.0,
    'AED': 0.98,
    'USD': 0.2666667,
}

CurrencyInactive = Currency.with_context(active_test=False)
currencies = {}
for code in DEMO_RATES_PER_SAR:
    currency = CurrencyInactive.search([('name', '=', code)], limit=1)
    if not currency:
        raise Exception(f'{code} currency is missing from the database.')
    if not currency.active:
        currency.action_unarchive()
    currencies[code] = currency

sar, aed, usd = currencies['SAR'], currencies['AED'], currencies['USD']

company_vals = {
    'name': company.name if company.name and company.name != 'My Company' else 'Demo Store',
    'country_id': sa.id,
}
company.write(company_vals)

# Switching company currency fails once journal items exist — keep current currency then.
if company.currency_id != sar:
    try:
        company.write({'currency_id': sar.id})
        print('Company currency set to SAR.')
    except UserError as err:
        print(
            f'Keeping company currency {company.currency_id.name} '
            f'(cannot switch to SAR: {err}). FX rates will be relative to it.'
        )
else:
    print('Company currency already SAR.')

company_currency = company.currency_id
company_code = company_currency.name
if company_code not in DEMO_RATES_PER_SAR:
    raise Exception(
        f'Company currency {company_code} is not in the demo FX table '
        f'({", ".join(DEMO_RATES_PER_SAR)}). Set company currency to SAR/AED/USD first.'
    )

# Convert "per SAR" rates into "per company currency" rates.
base = DEMO_RATES_PER_SAR[company_code]
demo_rates = {
    code: value / base
    for code, value in DEMO_RATES_PER_SAR.items()
}

today = fields.Date.context_today(company)
for code, rate in demo_rates.items():
    currency = currencies[code]
    existing = CurrencyRate.search([
        ('currency_id', '=', currency.id),
        ('name', '=', today),
        ('company_id', 'in', [company.id, False]),
    ], limit=1)
    vals = {
        'name': today,
        'currency_id': currency.id,
        'company_id': company.id,
        'rate': rate,
    }
    if existing:
        existing.write({'rate': rate, 'company_id': company.id})
    else:
        CurrencyRate.create(vals)

admin = env.ref('base.user_admin')
admin.password = 'admin'

# Enable built-in multi-currency + pricelists (no third-party addon needed).
settings = Settings.create({
    'group_multi_currency': True,
    'group_product_pricelist': True,
})
settings.execute()

website = Website.search([], limit=1)
if not website:
    raise Exception('No website found. Is website_sale installed?')
website.company_id = company

# Selectable website pricelists — one per currency (shop currency switcher).
pricelist_defs = [
    ('Public SAR', sar, 1),
    ('Public AED', aed, 2),
    ('Public USD', usd, 3),
]
for name, currency, sequence in pricelist_defs:
    pricelist = Pricelist.search([
        ('name', '=', name),
        ('website_id', '=', website.id),
    ], limit=1)
    vals = {
        'name': name,
        'currency_id': currency.id,
        'company_id': company.id,
        'website_id': website.id,
        'selectable': True,
        'sequence': sequence,
    }
    if pricelist:
        pricelist.write(vals)
    else:
        Pricelist.create(vals)
    print(f'Pricelist ready: {name} ({currency.name})')

# Publish a few demo products if the catalog is empty (list prices in company currency).
existing = ProductTemplate.search([('sale_ok', '=', True), ('is_published', '=', True)], limit=1)
if not existing:
    demos = [
        {'name': 'Desert Linen Shirt', 'list_price': 350.0},
        {'name': 'City Weekend Bag', 'list_price': 520.0},
        {'name': 'Canvas Sneakers', 'list_price': 420.0},
    ]
    for vals in demos:
        product = ProductTemplate.create({
            **vals,
            'type': 'consu',
            'sale_ok': True,
            'purchase_ok': False,
            'is_published': True,
        })
        print(
            f'Created product {product.display_name} '
            f'@ {product.list_price} {company_currency.name}'
        )

env.cr.commit()
print('Demo store configured.')
print(f'  company currency: {company_currency.name}')
print('  shop currencies: SAR, AED, USD')
print(f'  FX vs {company_currency.name}: {demo_rates}')
