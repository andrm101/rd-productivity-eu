import eurostat, pandas as pd

# Check nama_10_gdp PC_GDP rows to find savings (B8G)
df = eurostat.get_data_df("nama_10_gdp", flags=False)
df.columns = [c if not c.startswith("geo") else "country" for c in df.columns]
pc_gdp = df[df["unit"] == "PC_GDP"]["na_item"].unique().tolist()
print("nama_10_gdp na_items with PC_GDP:", pc_gdp)

# Check rd_p_persempoc exists
try:
    df2 = eurostat.get_data_df("rd_p_persempoc", flags=False)
    print("\nrd_p_persempoc shape:", df2.shape, "cols:", df2.columns.tolist()[:8])
except Exception as e:
    print("rd_p_persempoc error:", e)
