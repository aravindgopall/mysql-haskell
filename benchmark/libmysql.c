// make libmysql.c LDFLAGS="-g -O2 -L/usr/lib64/mysql -lmysqlclient -lpthread -lz -lm -lssl -lcrypto -ldl"

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <mysql/mysql.h>
#include <pthread.h>
#include <unistd.h>

#define THREAD_NUM  4
#define DBHOST      "localhost"
#define DBUSER      "root"
#define DBPASS      "pca"
#define DBPORT      3306
#define DBNAME      "dxponline"
#define DBSOCK      NULL //"/var/lib/mysql/mysql.sock"
#define DBPCNT      0

typedef struct ThreadArgsST
{
    int id;
    pthread_t *thread_id;
} ThreadArgs;

void *func(void *arg)
{
    ThreadArgs *args = (ThreadArgs *)arg;
    MYSQL_RES *result;
    MYSQL_ROW row;
    MYSQL_FIELD *field;
    unsigned int num_fields;
    unsigned int i;
    unsigned int timeout = 3000;
    const char *pStatement = "SHOW TABLES";
    mysql_thread_init();
    MYSQL *mysql = mysql_init(NULL);

    if (mysql == NULL)
    {
        printf("[%ld][%d]mysql init failed: %s\n", *args->thread_id, args->id, mysql_error(mysql));
        return (void *)0;
    }

    mysql_options(mysql, MYSQL_OPT_CONNECT_TIMEOUT, &timeout);

    if (mysql_real_connect(mysql, DBHOST, DBUSER, DBPASS, DBNAME, DBPORT, DBSOCK, DBPCNT) == NULL)
    {
        printf("[%ld][%d]connect failed: %s\n", *args->thread_id, args->id, mysql_error(mysql));
        mysql_close(mysql);
        mysql_thread_end();
        return (void *)0;
    }

    printf("[%ld][%d]connect succssfully\n", *args->thread_id, args->id);

    if (0 != mysql_real_query(mysql, pStatement, strlen(pStatement)))
    {
        printf("[%ld][%d]query failed: %s\n", *args->thread_id, args->id, mysql_error(mysql));
        mysql_close(mysql);
        mysql_thread_end();
        return (void *)0;
    }

    result = mysql_store_result(mysql);

    if (result == NULL)
    {
        printf("[%ld][%d]fetch result failed: %s\n", *args->thread_id, args->id, mysql_error(mysql));
        mysql_close(mysql);
        mysql_thread_end();
        return (void *)0;
    }

    num_fields = mysql_num_fields(result);
    printf("[%ld][%d]numbers of result: %d\n", *args->thread_id, args->id, num_fields);

    while (NULL != (field = mysql_fetch_field(result)))
    {
        printf("[%ld][%d]field name: %s\n", *args->thread_id, args->id, field->name);
    }

    while (NULL != (row = mysql_fetch_row(result)))
    {
        unsigned long *lengths;
        lengths = mysql_fetch_lengths(result);

        for (i = 0; i < num_fields; i++)
        {
            printf("[%ld][%d]{%.*s} ", *args->thread_id, args->id, (int) lengths[i], row[i] ? row[i] : "NULL");
        }

        printf("\n");
    }

    mysql_free_result(result);
    mysql_close(mysql);
    mysql_thread_end();
    return (void *)0;
}

int main(int argc, char *argv[])
{
    int thread_num;

    if (argc == 2)
    {
        thread_num = atoi(argv[1]);
    }
    else
    {
        thread_num = THREAD_NUM;
    }

    mysql_library_init(0, NULL, NULL);
    printf("argc: %d and thread_num: %d\n", argc, thread_num);

    do
    {
        pthread_t *pTh = new pthread_t[thread_num];
        ThreadArgs *pArgs = new ThreadArgs[thread_num];
        int i;

        for (i = 0; i < thread_num; i ++)
        {
            pArgs[i].id = i;
            pArgs[i].thread_id = &pTh[i];

            if (0 != pthread_create(&pTh[i], NULL, func, &pArgs[i]))
            {
                printf("pthread_create failed\n");
                continue;
            }
        }

        for (i = 0; i < thread_num; i ++)
        {
            pthread_join(pTh[i], NULL);
        }

        delete[] pTh;
        delete[] pArgs;
    }
    while (0);

    mysql_library_end();
    return 0;
}

