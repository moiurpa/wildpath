import os

# Importing the server builds a default app; keep it from creating wildpath.db.
os.environ.setdefault("WILDPATH_DB", ":memory:")
