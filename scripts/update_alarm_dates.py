#!/usr/bin/env python3
"""
Update ALARM entities' dates from 2026 to 2025 in graph_rag.db

This script:
1. Updates ALARM entities (description and metadata)
2. Updates/creates DATE entities (2026 -> 2025)
3. Updates relationships to point to correct DATE entities
4. Handles duplicate DATE entities (if 2025 version already exists)
"""

import sqlite3
import json
import sys
from pathlib import Path
from typing import List, Tuple


def update_alarm_dates(db_path: str, from_year: str = "2026", to_year: str = "2025"):
    """
    Update alarm dates in the database from one year to another.
    
    Args:
        db_path: Path to the graph_rag.db file
        from_year: Year to replace (default: "2026")
        to_year: Year to replace with (default: "2025")
    """
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()
    
    try:
        # Start transaction
        cursor.execute("BEGIN TRANSACTION")
        
        # Step 1: Get ALARM entities with the old year
        print(f"\n📋 Finding ALARM entities with year {from_year}...")
        cursor.execute(
            """SELECT id, name, description, metadata 
               FROM entities 
               WHERE type = 'ALARM' AND (description LIKE ? OR metadata LIKE ?)""",
            (f'%{from_year}%', f'%{from_year}%')
        )
        alarms = cursor.fetchall()
        
        if not alarms:
            print(f"✅ No ALARM entities found with year {from_year}")
        else:
            print(f"Found {len(alarms)} ALARM entities to update:")
            for alarm_id, name, desc, _ in alarms:
                print(f"  • {alarm_id} ({name}): {desc}")
        
        # Step 2: Update ALARM entities
        if alarms:
            print(f"\n🔧 Updating ALARM entities: {from_year} → {to_year}...")
            cursor.execute(
                """UPDATE entities 
                   SET description = REPLACE(description, ?, ?),
                       metadata = REPLACE(metadata, ?, ?)
                   WHERE type = 'ALARM'""",
                (from_year, to_year, from_year, to_year)
            )
            print(f"✅ Updated {cursor.rowcount} ALARM entities")
        
        # Step 3: Find DATE entities with the old year
        print(f"\n📅 Finding DATE entities with year {from_year}...")
        cursor.execute(
            """SELECT id, name, description 
               FROM entities 
               WHERE type = 'DATE' AND id LIKE ?""",
            (f'%{from_year}%',)
        )
        date_entities = cursor.fetchall()
        
        if not date_entities:
            print(f"✅ No DATE entities found with year {from_year}")
        else:
            print(f"Found {len(date_entities)} DATE entities to update:")
            for date_id, name, desc in date_entities:
                print(f"  • {date_id} ({name})")
        
        # Step 4: Update DATE entities
        date_mappings = []  # (old_id, new_id) pairs for relationship updates
        
        for old_date_id, old_name, old_desc in date_entities:
            new_date_id = old_date_id.replace(from_year, to_year)
            new_name = old_name.replace(from_year, to_year) if old_name else None
            new_desc = old_desc.replace(from_year, to_year) if old_desc else None
            
            # Check if new date already exists
            cursor.execute(
                "SELECT id FROM entities WHERE id = ? AND type = 'DATE'",
                (new_date_id,)
            )
            exists = cursor.fetchone()
            
            if exists:
                # New date exists, just delete the old one
                print(f"  ℹ️  {new_date_id} already exists, deleting {old_date_id}")
                cursor.execute("DELETE FROM entities WHERE id = ?", (old_date_id,))
            else:
                # Rename the old date to the new one
                print(f"  🔄 Renaming {old_date_id} → {new_date_id}")
                cursor.execute(
                    """UPDATE entities 
                       SET id = ?, name = ?, description = ?
                       WHERE id = ?""",
                    (new_date_id, new_name, new_desc, old_date_id)
                )
            
            date_mappings.append((old_date_id, new_date_id))
        
        # Step 5: Update relationships
        if date_mappings:
            print(f"\n🔗 Updating relationships...")
            total_updated = 0
            
            for old_date_id, new_date_id in date_mappings:
                # Update relationships where the DATE is the target
                cursor.execute(
                    """SELECT id, source_id, target_id, type 
                       FROM relationships 
                       WHERE target_id = ?""",
                    (old_date_id,)
                )
                relationships = cursor.fetchall()
                
                for rel_id, source_id, target_id, rel_type in relationships:
                    new_rel_id = rel_id.replace(old_date_id, new_date_id)
                    print(f"  • {rel_id} → {new_rel_id}")
                    
                    cursor.execute(
                        """UPDATE relationships 
                           SET id = ?, target_id = ?
                           WHERE id = ?""",
                        (new_rel_id, new_date_id, rel_id)
                    )
                    total_updated += 1
            
            print(f"✅ Updated {total_updated} relationships")
        
        # Commit transaction
        conn.commit()
        print(f"\n✅ All changes committed successfully!")
        
        # Verification
        print(f"\n🔍 Verification:")
        cursor.execute(
            """SELECT COUNT(*) FROM entities 
               WHERE type = 'ALARM' AND (description LIKE ? OR metadata LIKE ?)""",
            (f'%{from_year}%', f'%{from_year}%')
        )
        remaining_alarms = cursor.fetchone()[0]
        
        cursor.execute(
            """SELECT COUNT(*) FROM entities 
               WHERE type = 'DATE' AND id LIKE ?""",
            (f'%{from_year}%',)
        )
        remaining_dates = cursor.fetchone()[0]
        
        if remaining_alarms == 0 and remaining_dates == 0:
            print(f"  ✅ No remaining entities with year {from_year}")
        else:
            print(f"  ⚠️  Still found {remaining_alarms} ALARMs and {remaining_dates} DATEs with {from_year}")
        
    except Exception as e:
        conn.rollback()
        print(f"\n❌ Error occurred: {e}")
        print("   Changes rolled back.")
        raise
    finally:
        conn.close()


def main():
    """Main entry point"""
    # Default path relative to script location
    script_dir = Path(__file__).parent.parent
    db_path = script_dir / "knowledge_base" / "graph_rag.db"
    
    # Allow custom path as command line argument
    if len(sys.argv) > 1:
        db_path = Path(sys.argv[1])
    
    # Check if database exists
    if not db_path.exists():
        print(f"❌ Database not found: {db_path}")
        print(f"\nUsage: {sys.argv[0]} [path/to/graph_rag.db]")
        sys.exit(1)
    
    print(f"🗄️  Database: {db_path}")
    
    # Optional: specify years via command line
    from_year = sys.argv[2] if len(sys.argv) > 2 else "2026"
    to_year = sys.argv[3] if len(sys.argv) > 3 else "2025"
    
    print(f"🔄 Converting: {from_year} → {to_year}")
    
    # Run the update
    update_alarm_dates(str(db_path), from_year, to_year)
    
    print(f"\n✨ Done!")


if __name__ == "__main__":
    main()
