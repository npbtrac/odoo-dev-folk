# Configure the Odoo demo ecommerce store for Tamara (run via `odoo-bin shell`).
# Relies on env vars: TAMARA_API_TOKEN, TAMARA_NOTIFICATION_TOKEN, TAMARA_PUBLIC_KEY.
import os

from odoo import fields
from odoo.exceptions import UserError
from odoo.fields import Command

api_token = os.environ.get('TAMARA_API_TOKEN') or ''
notification_token = os.environ.get('TAMARA_NOTIFICATION_TOKEN') or 'sandbox-notification-token-placeholder'
public_key = os.environ.get('TAMARA_PUBLIC_KEY') or ''

Company = env['res.company']
Currency = env['res.currency']
CurrencyRate = env['res.currency.rate']
Country = env['res.country']
ProductTemplate = env['product.template']
Pricelist = env['product.pricelist']
Provider = env['payment.provider']
Website = env['website']
Settings = env['res.config.settings']

company = Company.browse(env.company.id)
sa = Country.search([('code', '=', 'SA')], limit=1)
ae = Country.search([('code', '=', 'AE')], limit=1)
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

# Company / website defaults for a KSA ecommerce demo.
company_vals = {
    'name': company.name if company.name and company.name != 'My Company' else 'Tamara Demo Store',
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
        {'name': 'Tamara Demo Sneakers', 'list_price': 420.0},
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

# Enable Tamara in sandbox mode with demo credentials.
# Tamara APIs support SAR/AED (and other GCC), not USD — USD stays shoppable via pricelist only.
website = env['website'].get_current_website()
provider = Provider.search([
    ('code', '=', 'tamara'),
    ('company_id', '=', website.company_id.id),
], limit=1) or Provider.search([('code', '=', 'tamara')], limit=1)
if not provider:
    raise Exception('payment_tamara provider record was not found. Is the module installed?')

tamara_countries = sa
if ae:
    tamara_countries |= ae

provider.write({
    'company_id': website.company_id.id,
    'tamara_state': 'sandbox',
    'state': 'test',
    'tamara_sandbox_mode': True,
    'is_published': True,
    'tamara_sandbox_api_token': api_token,
    'tamara_sandbox_notification_key': notification_token,
    'tamara_sandbox_public_key': public_key,
    'available_currency_ids': [Command.set((sar + aed).ids)],
    'available_country_ids': [Command.set(tamara_countries.ids)],
})


env.cr.commit()
print('Tamara provider configured.')
print(f'  company currency: {company_currency.name}')
print(f'  shop currencies: SAR, AED, USD (Tamara checkout: SAR + AED only)')
print(f'  FX vs {company_currency.name}: {demo_rates}')
print(f'  state={provider.state} sandbox={provider.tamara_sandbox_mode}')
print(f'  public_key={provider.tamara_sandbox_public_key}')
print(f'  webhook_id={provider.tamara_sandbox_webhook_id or "(pending / registration skipped)"}')
