package com.noop.data

/**
 * Fork (DX23876), Android without Room: the annotations the data-access declarations kept from Room. Nothing reads
 * them at run time; `Tools/gen_core_dao.py` reads them from the source and writes [CoreWhoopDao], which runs each
 * statement in the shared core's store. They keep Room's names and parameters, so the declarations read as before.
 */
@Retention(AnnotationRetention.SOURCE) @Target(AnnotationTarget.CLASS)
annotation class Dao

@Retention(AnnotationRetention.SOURCE) @Target(AnnotationTarget.CLASS)
annotation class Entity(
    val tableName: String = "",
    val primaryKeys: Array<String> = [],
    val indices: Array<Index> = [],
)

@Retention(AnnotationRetention.SOURCE)
annotation class Index(val value: Array<String> = [], val name: String = "", val unique: Boolean = false)

@Retention(AnnotationRetention.SOURCE) @Target(AnnotationTarget.FIELD, AnnotationTarget.VALUE_PARAMETER, AnnotationTarget.PROPERTY)
annotation class PrimaryKey(val autoGenerate: Boolean = false)

@Retention(AnnotationRetention.SOURCE) @Target(AnnotationTarget.FIELD, AnnotationTarget.VALUE_PARAMETER, AnnotationTarget.PROPERTY)
annotation class ColumnInfo(val name: String = "", val defaultValue: String = "")

@Retention(AnnotationRetention.SOURCE) @Target(AnnotationTarget.FUNCTION)
annotation class Query(val value: String)

@Retention(AnnotationRetention.SOURCE) @Target(AnnotationTarget.FUNCTION)
annotation class Insert(val onConflict: Int = OnConflictStrategy.ABORT)

@Retention(AnnotationRetention.SOURCE) @Target(AnnotationTarget.FUNCTION)
annotation class Upsert

@Retention(AnnotationRetention.SOURCE) @Target(AnnotationTarget.FUNCTION)
annotation class Update

@Retention(AnnotationRetention.SOURCE) @Target(AnnotationTarget.FUNCTION)
annotation class Transaction

object OnConflictStrategy {
    const val ABORT = 3
    const val REPLACE = 1
    const val IGNORE = 5
}
