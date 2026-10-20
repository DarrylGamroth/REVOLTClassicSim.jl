const _LENSLET_ROW_WIDTHS = (
    4,
    8,
    10,
    12,
    14,
    14,
    16,
    16,
    16,
    16,
    14,
    14,
    12,
    10,
    8,
    4,
)

"""
    valid_subapertures()

Return the exact 16×16 REVOLT Classic valid-subaperture mask. Its 188 selected
lenslets reproduce `validSubapMask.fits` from the maintained on-sky
configuration (raw SHA-256
`720bf7aa82d098e1bc5426b3364dd509adc609617b23127351d4d750b0ff596e`).
"""
function valid_subapertures()
    mask = falses(16, 16)
    for (row, width) in pairs(_LENSLET_ROW_WIDTHS)
        first_column = (size(mask, 2) - width) ÷ 2 + 1
        last_column = first_column + width - 1
        @views fill!(mask[row, first_column:last_column], true)
    end
    return mask
end
